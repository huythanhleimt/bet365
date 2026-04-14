const express = require('express');
const db = require('../models/db');

const router = express.Router();

// Get all matches
router.get('/', (req, res) => {
  try {
    const { status } = req.query;

    let query = 'SELECT * FROM matches ORDER BY match_date DESC';
    let params = [];

    if (status) {
      query = 'SELECT * FROM matches WHERE status = ? ORDER BY match_date DESC';
      params = [status];
    }

    const matches = db.prepare(query).all(...params);
    res.json({ matches });
  } catch (error) {
    console.error('Get matches error:', error);
    res.status(500).json({ error: 'Failed to fetch matches' });
  }
});

// Get single match by ID
router.get('/:id', (req, res) => {
  try {
    const { id } = req.params;
    const match = db.prepare('SELECT * FROM matches WHERE id = ?').get(id);

    if (!match) {
      return res.status(404).json({ error: 'Match not found' });
    }

    res.json({ match });
  } catch (error) {
    console.error('Get match error:', error);
    res.status(500).json({ error: 'Failed to fetch match' });
  }
});

module.exports = router;
