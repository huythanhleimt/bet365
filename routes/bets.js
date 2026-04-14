const express = require('express');
const jwt = require('jsonwebtoken');
const db = require('../models/db');

const router = express.Router();
const JWT_SECRET = process.env.JWT_SECRET || 'bet365-secret-key';

// Middleware to authenticate user
const authenticate = (req, res, next) => {
  try {
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return res.status(401).json({ error: 'No token provided' });
    }

    const token = authHeader.split(' ')[1];
    const decoded = jwt.verify(token, JWT_SECRET);
    req.userId = decoded.id;
    next();
  } catch (error) {
    res.status(401).json({ error: 'Invalid token' });
  }
};

// Place a bet
router.post('/', authenticate, (req, res) => {
  try {
    const { match_id, selection, amount } = req.body;

    if (!match_id || !selection || !amount) {
      return res.status(400).json({ error: 'Match, selection, and amount are required' });
    }

    // Get user
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(req.userId);
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }

    // Check balance
    if (amount > user.balance) {
      return res.status(400).json({ error: 'Insufficient balance' });
    }

    // Get match and odds
    const match = db.prepare('SELECT * FROM matches WHERE id = ?').get(match_id);
    if (!match) {
      return res.status(404).json({ error: 'Match not found' });
    }

    // Validate selection and get odds
    let odds;
    switch (selection) {
      case 'home':
        odds = match.home_odds;
        break;
      case 'draw':
        odds = match.draw_odds;
        break;
      case 'away':
        odds = match.away_odds;
        break;
      default:
        return res.status(400).json({ error: 'Invalid selection' });
    }

    if (!odds || odds <= 0) {
      return res.status(400).json({ error: 'Invalid odds' });
    }

    // Calculate potential payout
    const potentialPayout = Math.round(amount * odds * 100) / 100;

    // Deduct balance
    db.prepare('UPDATE users SET balance = balance - ? WHERE id = ?').run(amount, req.userId);

    // Create bet record
    const result = db.prepare(`
      INSERT INTO bets (user_id, match_id, selection, amount, odds, potential_payout, status)
      VALUES (?, ?, ?, ?, ?, ?, 'pending')
    `).run(req.userId, match_id, selection, amount, odds, potentialPayout);

    // Get updated balance
    const updatedUser = db.prepare('SELECT balance FROM users WHERE id = ?').get(req.userId);

    res.status(201).json({
      message: 'Bet placed successfully',
      bet: {
        id: result.lastInsertRowid,
        match_id,
        selection,
        amount,
        odds,
        potentialPayout,
        status: 'pending'
      },
      newBalance: updatedUser.balance
    });
  } catch (error) {
    console.error('Place bet error:', error);
    res.status(500).json({ error: 'Failed to place bet' });
  }
});

// Get user's bets
router.get('/my-bets', authenticate, (req, res) => {
  try {
    const bets = db.prepare(`
      SELECT b.*, m.home_team, m.away_team, m.match_date
      FROM bets b
      JOIN matches m ON b.match_id = m.id
      WHERE b.user_id = ?
      ORDER BY b.created_at DESC
    `).all(req.userId);

    res.json({ bets });
  } catch (error) {
    console.error('Get bets error:', error);
    res.status(500).json({ error: 'Failed to fetch bets' });
  }
});

module.exports = router;
