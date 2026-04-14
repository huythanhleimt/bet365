const Database = require('better-sqlite3');
const path = require('path');

const dbPath = process.env.DB_PATH || path.join(__dirname, '..', 'data', 'bet365.db');

// Ensure data directory exists
const fs = require('fs');
const dataDir = path.dirname(dbPath);
if (!fs.existsSync(dataDir)) {
  fs.mkdirSync(dataDir, { recursive: true });
}

const db = new Database(dbPath);

// Initialize database schema
db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    email TEXT UNIQUE NOT NULL,
    password TEXT NOT NULL,
    balance REAL DEFAULT 1000,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS matches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    home_team TEXT NOT NULL,
    away_team TEXT NOT NULL,
    match_date DATETIME NOT NULL,
    league TEXT DEFAULT 'Unknown',
    home_odds REAL NOT NULL,
    draw_odds REAL NOT NULL,
    away_odds REAL NOT NULL,
    status TEXT DEFAULT 'upcoming',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS bets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL,
    match_id INTEGER NOT NULL,
    selection TEXT NOT NULL,
    amount REAL NOT NULL,
    odds REAL NOT NULL,
    potential_payout REAL NOT NULL,
    status TEXT DEFAULT 'pending',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id),
    FOREIGN KEY (match_id) REFERENCES matches(id)
  );
`);

// Insert sample data if tables are empty
const userCount = db.prepare('SELECT COUNT(*) as count FROM users').get().count;
if (userCount === 0) {
  const bcrypt = require('bcryptjs');
  const hashedPassword = bcrypt.hashSync('password123', 10);

  // Create admin user
  db.prepare('INSERT INTO users (username, email, password, balance) VALUES (?, ?, ?, ?)')
    .run('admin', 'admin@bet365.com', hashedPassword, 10000);

  // Create demo user
  db.prepare('INSERT INTO users (username, email, password, balance) VALUES (?, ?, ?, ?)')
    .run('demo', 'demo@bet365.com', hashedPassword, 1000);
}

const matchCount = db.prepare('SELECT COUNT(*) as count FROM matches').get().count;
if (matchCount === 0) {
  // Insert sample matches
  const matches = [
    ['Manchester United', 'Liverpool', '2026-04-20 15:00:00', 'Premier League', 2.10, 3.40, 3.20],
    ['Real Madrid', 'Barcelona', '2026-04-21 20:00:00', 'La Liga', 2.25, 3.50, 2.90],
    ['Bayern Munich', 'Borussia Dortmund', '2026-04-22 18:30:00', 'Bundesliga', 1.75, 3.80, 4.20],
    ['Paris Saint-Germain', 'Marseille', '2026-04-23 21:00:00', 'Ligue 1', 1.50, 4.20, 5.50],
    ['Juventus', 'AC Milan', '2026-04-24 19:45:00', 'Serie A', 2.40, 3.20, 2.80],
    ['Arsenal', 'Chelsea', '2026-04-25 17:30:00', 'Premier League', 2.00, 3.30, 3.60],
    ['Atletico Madrid', 'Sevilla', '2026-04-26 16:00:00', 'La Liga', 1.85, 3.40, 4.00],
    ['Inter Milan', 'Napoli', '2026-04-27 20:45:00', 'Serie A', 2.30, 3.10, 3.00]
  ];

  const insertStmt = db.prepare(`
    INSERT INTO matches (home_team, away_team, match_date, league, home_odds, draw_odds, away_odds, status)
    VALUES (?, ?, ?, ?, ?, ?, ?, 'upcoming')
  `);

  for (const match of matches) {
    insertStmt.run(...match);
  }
}

module.exports = db;
