// WebView2 calls webview/webview doesn't expose: serving the configuration window's files from memory, and keyboard focus.
#define WEBVIEW_HEADER
#include "webview/api.h"

#include <windows.h>
#include <objbase.h>
#include <shlwapi.h>

#include <atomic>
#include <string>

#include "WebView2.h"

// Defined here rather than linked from uuid.lib / WebView2Guid.lib; the WebView2 ones are WebView2.h's MIDL_INTERFACE strings.
static const IID IID_IUnknown_ = {0x00000000, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const IID IID_ICoreWebView2_2_ = {0x9E8F0CF8, 0xE670, 0x4B5E, {0xB2, 0xBC, 0x73, 0xE0, 0x61, 0xE3, 0x18, 0x4C}};
static const IID IID_ICoreWebView2WebResourceRequestedEventHandler_ = {0xab00b74c, 0x15f1, 0x4646, {0x80, 0xe8, 0xe7, 0x63, 0x41, 0xd2, 0x5d, 0x71}};

extern "C" typedef int (*eve_webview_serve_fn)(const char *path, const char **body, size_t *body_len, const char **content_type);

static std::string toUtf8(const wchar_t *text) {
    int len = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 1) return {};
    std::string out(static_cast<size_t>(len - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text, -1, &out[0], len, nullptr, nullptr);
    return out;
}

static std::wstring toWide(const char *text) {
    int len = MultiByteToWideChar(CP_UTF8, 0, text, -1, nullptr, 0);
    if (len <= 1) return {};
    std::wstring out(static_cast<size_t>(len - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text, -1, &out[0], len);
    return out;
}

static ICoreWebView2Controller *controllerOf(webview_t w) {
    return static_cast<ICoreWebView2Controller *>(webview_get_native_handle(w, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER));
}

class ResourceHandler : public ICoreWebView2WebResourceRequestedEventHandler {
public:
    ResourceHandler(ICoreWebView2Environment *env, std::wstring prefix, eve_webview_serve_fn serve)
        : m_env(env), m_prefix(std::move(prefix)), m_serve(serve) {
        m_env->AddRef();
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++m_ref_count; }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG count = --m_ref_count;
        if (count == 0) delete this;
        return count;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **ppv) override {
        if (!ppv) return E_POINTER;
        if (IsEqualIID(riid, IID_IUnknown_) || IsEqualIID(riid, IID_ICoreWebView2WebResourceRequestedEventHandler_)) {
            *ppv = static_cast<ICoreWebView2WebResourceRequestedEventHandler *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    HRESULT STDMETHODCALLTYPE Invoke(ICoreWebView2 *, ICoreWebView2WebResourceRequestedEventArgs *args) override {
        ICoreWebView2WebResourceRequest *request = nullptr;
        HRESULT hr = args->get_Request(&request);
        if (FAILED(hr)) return hr;
        LPWSTR uri = nullptr;
        hr = request->get_Uri(&uri);
        request->Release();
        if (FAILED(hr)) return hr;

        std::wstring uri_w(uri);
        CoTaskMemFree(uri);
        std::wstring path_w = uri_w.compare(0, m_prefix.size(), m_prefix) == 0 ? uri_w.substr(m_prefix.size()) : std::wstring();
        size_t query = path_w.find_first_of(L"?#");
        if (query != std::wstring::npos) path_w.resize(query);
        std::string path = toUtf8(path_w.c_str());

        const char *body = nullptr;
        size_t body_len = 0;
        const char *content_type = nullptr;
        ICoreWebView2WebResourceResponse *response = nullptr;
        if (m_serve(path.c_str(), &body, &body_len, &content_type)) {
            IStream *stream = SHCreateMemStream(reinterpret_cast<const BYTE *>(body), static_cast<UINT>(body_len));
            if (!stream) return E_OUTOFMEMORY;
            std::wstring headers = L"Content-Type: " + toWide(content_type) + L"\r\nCache-Control: no-store";
            hr = m_env->CreateWebResourceResponse(stream, 200, L"OK", headers.c_str(), &response);
            stream->Release();
        } else {
            hr = m_env->CreateWebResourceResponse(nullptr, 404, L"Not Found", L"", &response);
        }
        if (FAILED(hr)) return hr;
        hr = args->put_Response(response);
        response->Release();
        return hr;
    }

private:
    ~ResourceHandler() { m_env->Release(); }

    ICoreWebView2Environment *m_env;
    std::wstring m_prefix;
    eve_webview_serve_fn m_serve;
    std::atomic<ULONG> m_ref_count{1};
};

// Answers every request under prefix (e.g. "https://eve-maj.invalid/") with serve, so the page never reaches the network.
extern "C" HRESULT eve_webview_serve(webview_t w, const char *prefix, eve_webview_serve_fn serve) {
    ICoreWebView2Controller *controller = controllerOf(w);
    if (!controller) return E_POINTER;
    ICoreWebView2 *webview = nullptr;
    HRESULT hr = controller->get_CoreWebView2(&webview);
    if (FAILED(hr)) return hr;

    ICoreWebView2_2 *webview2 = nullptr;
    ICoreWebView2Environment *env = nullptr;
    hr = webview->QueryInterface(IID_ICoreWebView2_2_, reinterpret_cast<void **>(&webview2));
    if (SUCCEEDED(hr)) {
        hr = webview2->get_Environment(&env);
        webview2->Release();
    }
    if (FAILED(hr)) {
        webview->Release();
        return hr;
    }

    std::wstring prefix_w = toWide(prefix);
    hr = webview->AddWebResourceRequestedFilter((prefix_w + L"*").c_str(), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
    if (SUCCEEDED(hr)) {
        auto *handler = new ResourceHandler(env, prefix_w, serve);
        EventRegistrationToken token;
        hr = webview->add_WebResourceRequested(handler, &token);
        handler->Release();
    }
    env->Release();
    webview->Release();
    return hr;
}

extern "C" void eve_webview_focus(webview_t w) {
    if (ICoreWebView2Controller *controller = controllerOf(w)) {
        controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
    }
}
