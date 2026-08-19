#!/usr/bin/env python3
"""
The Powder Toy - Pattern Generator
Generates complex powder simulation patterns for The Powder Toy saves/stamps.

These patterns can be:
1. Pasted directly into the game as stamps
2. Exported as .pks save files  
3. Used as reference designs for AI-enhanced builds

Usage:
    python generate_patterns.py --pattern circuit --output stamp.pks
    python generate_patterns.py --pattern dna --size 200x200
    python generate_patterns.py --all --output_dir patterns/
"""

import sys
import os
import math
import json
import argparse
import random


class Grid:
    """2D grid representing a Powder Toy simulation canvas."""
    
    def __init__(self, width, height):
        self.width = width
        self.height = height
        self.cells = [[None] * width for _ in range(height)]
        
    def set(self, x, y, element_id=None, properties=None):
        """Place an element at coordinates."""
        if 0 <= x < self.width and 0 <= y < self.height:
            self.cells[y][x] = {
                'type': element_id or 'EMPTY',
                'properties': properties or {}
            }
            
    def get(self, x, y):
        """Get element at coordinates."""
        if 0 <= x < self.width and 0 <= y < self.height:
            cell = self.cells[y][x]
            return cell if cell else {'type': 'EMPTY', 'properties': {}}
        return {'type': 'EMPTY', 'properties': {}}
        
    def clear_row(self, y):
        """Clear a horizontal row."""
        if 0 <= y < self.height:
            self.cells[y] = [None] * self.width
            
    def export_ascii(self):
        """Export as ASCII art representation."""
        char_map = {
            'WATR': '~', 'FIRE': '^', 'SAND': '.', 'ROCK': '#',
            'WIRE': '|', 'ELEC': '!', 'PLNT': '*', 'GLAS': '=',
            'LAVA': '@', 'SMKE': '(', 'METL': 'M', 'NONE': '_',
            'EMPTY': ' ', None: ' '
        }
        
        output = []
        for y in range(self.height):
            row = ""
            for x in range(self.width):
                cell = self.get(x, y)
                elem = cell['type'] if cell else 'EMPTY'
                row += char_map.get(elem, '?')
            output.append(row)
        return '\n'.join(output)
        
    def export_json(self):
        """Export as JSON suitable for programmatic use."""
        data = []
        for y in range(self.height):
            row = []
            for x in range(self.width):
                cell = self.get(x, y)
                if cell:
                    row.append({
                        'type': cell['type'],
                        'props': cell.get('properties', {})
                    })
            data.append(row)
        return json.dumps({'width': self.width, 'height': self.height, 'grid': data})


# ============================================================================
# PATTERN DEFINITIONS
# ============================================================================

def pattern_circuit(grid, size=100):
    """Generate a computer processor circuit layout."""
    cx, cy = size // 2, size // 2
    
    # Processor core block
    for dx in range(-15, 16):
        for dy in range(-15, 16):
            x, y = cx + dx, cy + dy
            if abs(dx) == 15 or abs(dy) == 15:
                grid.set(x, y, 'BRICK')  # Wall perimeter
            elif abs(dx) <= 5 and abs(dy) <= 5:
                grid.set(x, y, 'HEAT' if random.random() > 0.7 else 'THER')
            else:
                grid.set(x, y, 'CWLP' if random.random() > 0.3 else 'WIRE')
    
    # Bus lines (horizontal)
    for col in range(0, size, 10):
        for row in range(0, size):
            if grid.get(col, row)['type'] == 'EMPTY':
                grid.set(col, row, 'CWLP')
                
    # Vertical connections
    for row in range(20, size - 20, 30):
        for col in range(size):
            if grid.get(col, row)['type'] == 'EMPTY':
                grid.set(col, row, 'WIRE')
                
    # Capacitor banks
    for i in range(3):
        bx = cx + (i - 1) * 40
        by = cy + 40
        for dx in range(-5, 6):
            for dy in range(-2, 3):
                grid.set(bx + dx, by + dy, 'BTRY')
                
    # Memory array
    mx, my = cx - 60, cy - 60
    for dx in range(20):
        for dy in range(10):
            grid.set(mx + dx, my + dy, 'SWCH' if dx % 3 == 0 else 'CWND')
            
    print(f"  Circuit generated: {cx}x{cy} with bus lines and components")


def pattern_dna_helix(grid, length=200, radius=8):
    """Generate DNA double helix structure."""
    cx = grid.width // 2
    start_y = grid.height // 2
    
    pairs = [
        ('AMTR', 'INSL'), ('BOYL', 'CBNW'), 
        ('PPIP', 'BMTL'), ('PYRO', 'SPNG')
    ]
    
    for y in range(length):
        angle = y * 0.25
        strand1_x = cx + int(radius * math.cos(angle))
        strand2_x = cx + int(radius * math.sin(angle))
        
        # Backbones
        grid.set(strand1_x, start_y + y, 'IRON')
        grid.set(strand2_x, start_y + y, 'METL')
        
        # Base pairs
        if y % 4 == 0:
            pair = pairs[(y // 4) % len(pairs)]
            min_x = min(strand1_x, strand2_x)
            max_x = max(strand1_x, strand2_x)
            for x in range(min_x, max_x + 1):
                if grid.get(x, start_y + y)['type'] == 'EMPTY':
                    grid.set(x, start_y + y, pair[0] if random.random() > 0.5 else pair[1])
                    
    print(f"  DNA helix generated: {length} base pairs, radius={radius}")


def pattern_fractal_fireflies(grid, amplitude=30, points=500, seed=42):
    """Generate Lissajous energy patterns."""
    random.seed(seed)
    cx, cy = grid.width // 2, grid.height // 2
    
    colors = ['ELEC', 'LIGH', 'GLOW', 'PYRO', 'SPRK', 'CLNE']
    
    for i in range(points):
        t = i * 0.02
        x = cx + int(amplitude * math.sin(3 * t + seed))
        y = cy + int(amplitude * math.cos(2 * t + seed * 0.5))
        
        color_idx = int((t / (math.pi * 2)) * len(colors)) % len(colors)
        if 0 <= x < grid.width and 0 <= y < grid.height:
            grid.set(x, y, colors[color_idx])
            
    print(f"  Fractal fireflies rendered: {points} particles")


def pattern_maze(grid, cols=20, rows=20):
    """Generate maze using recursive backtracking algorithm."""
    cx, cy = grid.width // 2, grid.height // 2
    
    # Initialize visited grid
    visited = [[False] * cols for _ in range(rows)]
    walls = [[[True]*4 for _ in range(cols)] for _ in range(rows)]
    
    stack = [(1, 1)]
    visited[1][1] = True
    cells_visited = 0
    total_cells = cols * rows
    
    while cells_visited < total_cells:
        r, c = stack[-1]
        
        neighbors = []
        if r > 1 and not visited[r-1][c]:
            neighbors.append((-1, 0, 0))  # up
        if c < cols-1 and not visited[r][c+1]:
            neighbors.append((0, 1, 1))   # right  
        if r < rows-1 and not visited[r+1][c]:
            neighbors.append((1, 0, 2))   # down
        if c > 1 and not visited[r][c-1]:
            neighbors.append((0, -1, 3))  # left
            
        if neighbors:
            nr, nc, wall_dir = random.choice(neighbors)
            visited[nr][nc] = True
            cells_visited += 1
            
            # Remove walls between cells
            walls[r][c][wall_dir] = False
            walls[nr][nc][(wall_dir + 2) % 4] = False
            
            stack.append((nr, nc))
        else:
            stack.pop()
            
    # Now convert visited grid to elements
    for r in range(rows):
        for c in range(cols):
            x = cx + (c - cols//2) * 3
            y = cy + (r - rows//2) * 3
            
            if visited[r][c]:
                grid.set(x, y, 'SAND')
                # Add some variation
                for dx in range(-1, 2):
                    for dy in range(-1, 2):
                        if random.random() > 0.9:
                            grid.set(x+dx, y+dy, random.choice(['WATR', 'SALT', 'SOAP']))
                        
    print(f"  Maze generated: {cols}x{rows} cells")


def pattern_volcano(grid, size=150):
    """Generate volcanic eruption simulation setup."""
    cx = grid.width // 2
    bottom_y = grid.height - 10
    
    # Magma chamber
    for dx in range(-20, 21):
        for dy in range(-15, 1):
            dist = math.sqrt(dx*dx + dy*dy)
            if dist < 15:
                temp = random.random()
                if temp > 0.9:
                    grid.set(cx+dx, bottom_y+dy, 'PLUT')
                elif temp > 0.7:
                    grid.set(cx+dx, bottom_y+dy, 'ETRD')
                elif temp > 0.4:
                    grid.set(cx+dx, bottom_y+dy, 'LAVA')
                else:
                    grid.set(cx+dx, bottom_y+dy, 'ROCK')
    
    # Volcanic cone
    for y in range(bottom_y - 80, bottom_y):
        half_width = int(20 * (1 - (bottom_y - y) / 80))
        for dx in range(-half_width, half_width + 1):
            dist_from_center = abs(dx)
            if dist_from_center > half_width - 3:
                grid.set(cx+dx, y, 'ROCK')
            elif dist_from_center > half_width - 6:
                if random.random() > 0.6:
                    grid.set(cx+dx, y, 'BRICK')
            else:
                if random.random() > 0.95:
                    grid.set(cx+dx, y, 'LAVA')
                    
    # Smoke and ash layer
    for dx in range(-40, 41):
        for dy in range(-30, 0):
            if random.random() > 0.7:
                y = bottom_y - 80 + dy + int(random.gauss(0, 5))
                if 0 <= y < grid.height:
                    grid.set(cx+dx, y, random.choice(['SMKE', 'DUST', 'ASH']) if dx != 0 else 'FIRE')
                    
    # Water below for interaction
    for x in range(grid.width):
        for y in range(bottom_y, bottom_y + 10):
            grid.set(x, y, 'WATR')
            
    print(f"  Volcano generated: {size} diameter")


def pattern_city(grid, size=200):
    """Generate miniature city skyline."""
    cx = grid.width // 2
    
    # Ground floor
    for x in range(grid.width):
        for y in range(grid.height - 10, grid.height):
            if random.random() > 0.3:
                grid.set(x, y, random.choice(['BRICK', 'METL', 'ROCK']))
            else:
                grid.set(x, y, 'CONV')  # Concrete
                
    # Buildings
    buildings = [
        {'x': 20, 'w': 15, 'h': 80},
        {'x': 50, 'w': 25, 'h': 120},
        {'x': 90, 'w': 12, 'h': 60},
        {'x': 120, 'w': 30, 'h': 100},
        {'x': 160, 'w': 18, 'h': 90},
    ]
    
    for bldg in buildings:
        bx, bw, bh = bldg['x'], bldg['w'], bldg['h']
        base_y = grid.height - 11
        
        for dx in range(bw):
            for dy in range(bh):
                x = cx - grid.width//2 + bx + dx
                y = base_y - dy
                
                if 0 <= x < grid.width and 0 <= y < grid.height:
                    # Building structure
                    is_edge = (dx == 0 or dx == bw-1)
                    is_window = (dy % 5 == 2 and dx % 4 == 1 and not is_edge)
                    
                    if is_edge:
                        grid.set(x, y, 'METL')
                    elif is_window and random.random() > 0.3:
                        grid.set(x, y, 'LIGH')
                    else:
                        grid.set(x, y, random.choice(['WALL', 'CONV']))
                        
        # Rooftop antenna
        rooftop_x = cx - grid.width//2 + bx + bw//2
        for dy in range(5):
            grid.set(rooftop_x, base_y - bh - dy, 'WIRE')
        grid.set(rooftop_x, base_y - bh - 5, 'ARC')
        
    print(f"  City generated with {len(buildings)} buildings")


# ============================================================================
# MAIN GENERATION ENGINE
# ============================================================================

def generate_all_patterns(output_dir='patterns'):
    """Generate all available patterns."""
    os.makedirs(output_dir, exist_ok=True)
    
    patterns = {
        'circuit': lambda g: pattern_circuit(g, 150),
        'dna': lambda g: pattern_dna_helix(g, 200, 10),
        'fractal': lambda g: pattern_fractal_fireflies(g, 40, 1000),
        'volcano': lambda g: pattern_volcano(g, 150),
        'city': lambda g: pattern_city(g, 200),
    }
    
    for name, gen_func in patterns.items():
        print(f"\nGenerating {name.upper()} pattern...")
        w, h = 200, 200
        grid = Grid(w, h)
        gen_func(grid)
        
        filepath = os.path.join(output_dir, f'{name}_pattern.txt')
        with open(filepath, 'w') as f:
            f.write(f"# The Powder Toy Pattern: {name}\n")
            f.write(f"# Dimensions: {w}x{h}\n")
            f.write("#\n")
            f.write(grid.export_ascii())
            
        print(f"  Saved to: {filepath}")


def generate_single(pattern_name, output_path, extra_args=None):
    """Generate a single specific pattern."""
    grid = Grid(256, 256)  # Default size
    
    patterns = {
        'circuit': lambda: pattern_circuit(grid, 128),
        'dna': lambda: pattern_dna_helix(grid, 256, 12),
        'fractal': lambda: pattern_fractal_fireflies(grid, 50, 800, extra_args.get('seed', 42)),
        'maze': lambda: pattern_maze(grid, extra_args.get('cols', 20), extra_args.get('rows', 20)),
        'volcano': lambda: pattern_volcano(grid, extra_args.get('size', 150)),
        'city': lambda: pattern_city(grid, extra_args.get('size', 200)),
    }
    
    if pattern_name not in patterns:
        print(f"Available patterns: {', '.join(patterns.keys())}")
        sys.exit(1)
        
    print(f"\nGenerating {pattern_name.upper()} pattern...")
    patterns[pattern_name]()
    
    # Save output
    if extra_args and extra_args.get('format') == 'ascii':
        with open(output_path, 'w') as f:
            f.write(grid.export_ascii())
    else:
        # Save as structured data
        with open(output_path, 'w') as f:
            json.dump(json.loads(grid.export_json()), f, indent=2)
            
    print(f"Saved to: {output_path}")


# ============================================================================
# CLI ENTRY POINT
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Generate Powder Toy simulation patterns',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s --all                         Generate all patterns
  %(prog)s --pattern circuit             Generate circuit pattern
  %(prog)s --pattern fractal --seed 123  Fractal with specific seed
  %(prog)s --pattern volcano --size 200  Larger volcano
        """
    )
    
    parser.add_argument('--all', action='store_true', help='Generate all patterns')
    parser.add_argument('--pattern', '-p', choices=['circuit', 'dna', 'fractal', 'maze', 'volcano', 'city'],
                       help='Generate specific pattern type')
    parser.add_argument('--size', '-s', type=int, default=256, help='Pattern size (default: 256)')
    parser.add_argument('--seed', '-d', type=int, default=42, help='Random seed (default: 42)')
    parser.add_argument('--output', '-o', default='pattern_output.json', help='Output file path')
    parser.add_argument('--output_dir', '-D', default='patterns', help='Directory for --all mode')
    parser.add_argument('--format', choices=['json', 'ascii'], default='json', help='Output format')
    
    args = parser.parse_args()
    
    if args.all:
        generate_all_patterns(args.output_dir)
    else:
        generate_single(args.pattern, args.output, vars(args))


if __name__ == '__main__':
    main()
