// The About logo's hidden snake game.
import { scrollBehavior } from './layout.js';

let logoClickCount = 0;
let snakeGameActive = false;
let snakeGameLoop = null;

document.addEventListener('DOMContentLoaded', function() {
    const logo = document.getElementById('about-logo');
    if (logo) {
        logo.addEventListener('click', handleLogoClick);
    }
});

function handleLogoClick() {
    logoClickCount++;

    if (logoClickCount === 5) {
        showSnakeGame();
        logoClickCount = 0;
    }
}

function showSnakeGame() {
    const container = document.getElementById('snake-game-container');
    const canvas = document.getElementById('snake-game');
    
    if (!container || !canvas) return;
    
    container.style.display = 'block';
    snakeGameActive = true;
    
    container.scrollIntoView({ behavior: scrollBehavior(), block: 'center' });

    initSnakeGame(canvas);

    const escapeHandler = function(e) {
        if (e.key === 'Escape' && snakeGameActive) {
            hideSnakeGame();
            document.removeEventListener('keydown', escapeHandler);
        }
    };
    document.addEventListener('keydown', escapeHandler);
}

function hideSnakeGame() {
    const container = document.getElementById('snake-game-container');
    if (container) {
        container.style.display = 'none';
    }
    snakeGameActive = false;
    if (snakeGameLoop) {
        cancelAnimationFrame(snakeGameLoop);
        snakeGameLoop = null;
    }
}

function initSnakeGame(canvas) {
    const context = canvas.getContext('2d');
    const grid = 16;
    let count = 0;
    
    const snake = {
        x: 160,
        y: 160,
        dx: grid,
        dy: 0,
        cells: [],
        maxCells: 4
    };
    
    const apple = {
        x: 320,
        y: 320
    };
    
    function getRandomInt(min, max) {
        return Math.floor(Math.random() * (max - min)) + min;
    }
    
    function loop() {
        if (!snakeGameActive) return;
        
        snakeGameLoop = requestAnimationFrame(loop);
        
        // Slow game loop to 7.5 fps (60/7.5 = 8)
        if (++count < 8) {
            return;
        }
        
        count = 0;
        context.clearRect(0, 0, canvas.width, canvas.height);
        
        snake.x += snake.dx;
        snake.y += snake.dy;

        if (snake.x < 0) {
            snake.x = canvas.width - grid;
        } else if (snake.x >= canvas.width) {
            snake.x = 0;
        }
        
        if (snake.y < 0) {
            snake.y = canvas.height - grid;
        } else if (snake.y >= canvas.height) {
            snake.y = 0;
        }
        
        snake.cells.unshift({x: snake.x, y: snake.y});

        if (snake.cells.length > snake.maxCells) {
            snake.cells.pop();
        }

        context.fillStyle = 'white';
        context.fillRect(apple.x, apple.y, grid - 1, grid - 1);

        context.fillStyle = 'white';
        snake.cells.forEach(function(cell, index) {
            context.fillRect(cell.x, cell.y, grid - 1, grid - 1);

            if (cell.x === apple.x && cell.y === apple.y) {
                snake.maxCells++;
                apple.x = getRandomInt(0, 25) * grid;
                apple.y = getRandomInt(0, 25) * grid;
            }

            for (let i = index + 1; i < snake.cells.length; i++) {
                if (cell.x === snake.cells[i].x && cell.y === snake.cells[i].y) {
                    snake.x = 160;
                    snake.y = 160;
                    snake.cells = [];
                    snake.maxCells = 4;
                    snake.dx = grid;
                    snake.dy = 0;
                    apple.x = getRandomInt(0, 25) * grid;
                    apple.y = getRandomInt(0, 25) * grid;
                }
            }
        });
    }
    
    // Keyboard controls - prevent arrow key scrolling when game is active
    const snakeKeyHandler = function(e) {
        if (!snakeGameActive) return;

        if (e.which >= 37 && e.which <= 40) {
            e.preventDefault();
            e.stopPropagation();
        }
        
        if (e.which === 37 && snake.dx === 0) {
            snake.dx = -grid;
            snake.dy = 0;
        }
        else if (e.which === 38 && snake.dy === 0) {
            snake.dy = -grid;
            snake.dx = 0;
        }
        else if (e.which === 39 && snake.dx === 0) {
            snake.dx = grid;
            snake.dy = 0;
        }
        else if (e.which === 40 && snake.dy === 0) {
            snake.dy = grid;
            snake.dx = 0;
        }
    };
    
    document.addEventListener('keydown', snakeKeyHandler, true);

    snakeGameLoop = requestAnimationFrame(loop);
}
