const express = require('express');
const jwt = require('jsonwebtoken');
const db = require('../models/db');

const router = express.Router();
const JWT_SECRET = process.env.JWT_SECRET || 'bet365-secret-key';
const ADMIN_SECRET = process.env.ADMIN_SECRET || 'admin-secret';

// Middleware to authenticate admin
const authenticateAdmin = (req, res, next) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'No token provided' });
    }

    const token = authHeader.split(' ')[1];
    const decoded = jwt.verify(token, JWT_SECRET);

    // Check if user is admin (simplified - in production, check admin flag)
    if (decoded.username !== 'admin') {
      return res.status(403).json({ error: 'Admin access required' });
    }

    req.userId = decoded.id;
    next();
  } catch (error) {
    res.status(401).json({ error: 'Invalid token' });
  }
};

// Admin login
router.post('/login', (req, res) => {
  try {
    const { secret } = req.body;

    if (secret !== ADMIN_SECRET) {
      return res.status(401).json({ error: 'Invalid admin secret' });
    }

    const token = jwt.sign(
      { id: 1, username: 'admin' },
      JWT_SECRET,
      { expiresIn: '1h' }
    );

    res.json({ message: 'Admin login successful', token });
  } catch (error) {
    res.status(500).json({ error: 'Login failed' });
  }
});

// Create match
router.post('/matches', authenticateAdmin, (req, res) => {
  try {
    const { home_team, away_team, match_date, league, home_odds, draw_odds, away_odds } = req.body;

    if (!home_team || !away_team || !match_date || !home_odds || !draw_odds || !away_odds) {
      return res.status(400).json({ error: 'All fields are required' });
    }

    const result = db.prepare(`
      INSERT INTO matches (home_team, away_team, match_date, league, home_odds, draw_odds, away_odds, status)
      VALUES (?, ?, ?, ?, ?, ?, ?, 'upcoming')
    `).run(home_team, away_team, match_date, league || 'Unknown', home_odds, draw_odds, away_odds);

    res.status(201).json({
      message: 'Match created successfully',
      match_id: result.lastInsertRowid
    });
  } catch (error) {
    console.error('Create match error:', error);
    res.status(500).json({ error: 'Failed to create match' });
  }
});

// Update odds
router.put('/matches/:id/odds', authenticateAdmin, (req, res) => {
  try {
    const { id } = req.params;
    const { home_odds, draw_odds, away_odds } = req.body;

    const match = db.prepare('SELECT * FROM matches WHERE id = ?').get(id);
    if (!match) {
      return res.status(404).json({ error: 'Match not found' });
    }

    db.prepare(`
      UPDATE matches SET home_odds = ?, draw_odds = ?, away_odds = ?
      WHERE id = ?
    `).run(home_odds, draw_odds, away_odds, id);

    res.json({ message: 'Odds updated successfully' });
  } catch (error) {
    console.error('Update odds error:', error);
    res.status(500).json({ error: 'Failed to update odds' });
  }
});

// Set match result
router.put('/matches/:id/result', authenticateAdmin, (req, res) => {
  try {
    const { id } = req.params;
    const { result } = req.body; // 'home', 'draw', 'away'

    const match = db.prepare('SELECT * FROM matches WHERE id = ?').get(id);
    if (!match) {
      return res.status(404).json({ error: 'Match not found' });
    }

    // Update match status
    db.prepare('UPDATE matches SET status = ? WHERE id = ?').run('finished', id);

    // Process bets
    db.prepare(`
      UPDATE bets SET status = 'won' WHERE match_id = ? AND selection = ?
    `).run(id, result);

    db.prepare(`
      UPDATE bets SET status = 'lost' WHERE match_id = ? AND selection != ?
    `).run(id, result);

    // Payout winnings
    const wonBets = db.prepare('SELECT * FROM bets WHERE match_id = ? AND status = ?').all(id, 'won');
    for (const bet of wonBets) {
      db.prepare('UPDATE users SET balance = balance + ? WHERE id = ?').run(bet.potential_payout, bet.user_id);
    }

    res.json({ message: 'Match result set and bets processed successfully' });
  } catch (error) {
    console.error('Set result error:', error);
    res.status(500).json({ error: 'Failed to set result' });
  }
});

// Get all users
router.get('/users', authenticateAdmin, (req, res) => {
  try {
    const users = db.prepare('SELECT id, username, email, balance, created_at FROM users').all();
    res.json({ users });
  } catch (error) {
    console.error('Get users error:', error);
    res.status(500).json({ error: 'Failed to fetch users' });
  }
});

// Get all bets
router.get('/bets', authenticateAdmin, (req, res) => {
  try {
    const bets = db.prepare(`
      SELECT b.*, u.username, m.home_team, m.away_team
      FROM bets b
      JOIN users u ON b.user_id = u.id
      JOIN matches m ON b.match_id = m.id
      ORDER BY b.created_at DESC
    `).all();

    res.json({ bets });
  } catch (error) {
    console.error('Get bets error:', error);
    res.status(500).json({ error: 'Failed to fetch bets' });
  }
});

module.exports = router;
