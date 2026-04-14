// State
let currentUser = null;
let currentToken = null;
let currentMatch = null;

// API helper
const api = {
  async request(endpoint, options = {}) {
    const headers = {
      'Content-Type': 'application/json',
      ...options.headers
    };

    if (currentToken) {
      headers['Authorization'] = `Bearer ${currentToken}`;
    }

    const response = await fetch(`/api${endpoint}`, {
      ...options,
      headers
    });

    const data = await response.json();

    if (!response.ok) {
      throw new Error(data.error || 'Request failed');
    }

    return data;
  },

  auth: {
    login: (username, password) => api.request('/auth/login', {
      method: 'POST',
      body: JSON.stringify({ username, password })
    }),
    register: (username, email, password) => api.request('/auth/register', {
      method: 'POST',
      body: JSON.stringify({ username, email, password })
    }),
    me: () => api.request('/auth/me')
  },

  matches: {
    getAll: (status) => api.request(`/matches${status ? `?status=${status}` : ''}`),
    getById: (id) => api.request(`/matches/${id}`)
  },

  bets: {
    place: (matchId, selection, amount) => api.request('/bets', {
      method: 'POST',
      body: JSON.stringify({ match_id: matchId, selection, amount })
    }),
    getMyBets: () => api.request('/bets/my-bets')
  }
};

// DOM Elements
const authSection = document.getElementById('authSection');
const mainContent = document.getElementById('mainContent');
const navLinks = document.getElementById('navLinks');
const loginForm = document.getElementById('loginForm');
const registerForm = document.getElementById('registerForm');
const matchesGrid = document.getElementById('matchesGrid');
const betsList = document.getElementById('betsList');
const betModal = document.getElementById('betModal');
const toast = document.getElementById('toast');

// Toast notification
function showToast(message, type = 'success') {
  toast.textContent = message;
  toast.className = `toast ${type}`;
  setTimeout(() => {
    toast.classList.add('hidden');
  }, 3000);
}

// Auth functions
async function handleLogin(e) {
  e.preventDefault();
  const username = document.getElementById('loginUsername').value;
  const password = document.getElementById('loginPassword').value;

  try {
    const data = await api.auth.login(username, password);
    currentToken = data.token;
    currentUser = data.user;
    localStorage.setItem('token', currentToken);
    localStorage.setItem('user', JSON.stringify(currentUser));
    showToast('Login successful!');
    updateUI();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

async function handleRegister(e) {
  e.preventDefault();
  const username = document.getElementById('registerUsername').value;
  const email = document.getElementById('registerEmail').value;
  const password = document.getElementById('registerPassword').value;

  try {
    const data = await api.auth.register(username, email, password);
    currentToken = data.token;
    currentUser = data.user;
    localStorage.setItem('token', currentToken);
    localStorage.setItem('user', JSON.stringify(currentUser));
    showToast('Registration successful!');
    updateUI();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

function handleLogout() {
  currentToken = null;
  currentUser = null;
  localStorage.removeItem('token');
  localStorage.removeItem('user');
  updateUI();
  showToast('Logged out successfully');
}

// Update UI based on auth state
function updateUI() {
  if (currentUser) {
    authSection.classList.add('hidden');
    mainContent.classList.remove('hidden');

    document.getElementById('usernameDisplay').textContent = currentUser.username;
    document.getElementById('balanceDisplay').textContent = currentUser.balance.toFixed(2);

    navLinks.innerHTML = `
      <span>Balance: $${currentUser.balance.toFixed(2)}</span>
      <button class="btn-logout" onclick="handleLogout()">Logout</button>
    `;

    loadMatches();
    loadBets();
  } else {
    authSection.classList.remove('hidden');
    mainContent.classList.add('hidden');
    navLinks.innerHTML = '';
  }
}

// Load matches
async function loadMatches() {
  try {
    const data = await api.matches.getAll('upcoming');
    matchesGrid.innerHTML = data.matches.map(match => `
      <div class="match-card">
        <div class="match-header">
          <span class="match-date">${new Date(match.match_date).toLocaleDateString()}</span>
          <span class="match-league">${match.league}</span>
        </div>
        <div class="match-teams">
          <div class="team">
            <div class="team-name">${match.home_team}</div>
          </div>
          <div class="vs">vs</div>
          <div class="team">
            <div class="team-name">${match.away_team}</div>
          </div>
        </div>
        <div class="odds-container">
          <button class="odd-btn" onclick="openBetModal(${match.id}, 'home', ${match.home_odds})">
            <span class="odd-label">Home</span>
            <span class="odd-value">${match.home_odds.toFixed(2)}</span>
          </button>
          <button class="odd-btn" onclick="openBetModal(${match.id}, 'draw', ${match.draw_odds})">
            <span class="odd-label">Draw</span>
            <span class="odd-value">${match.draw_odds.toFixed(2)}</span>
          </button>
          <button class="odd-btn" onclick="openBetModal(${match.id}, 'away', ${match.away_odds})">
            <span class="odd-label">Away</span>
            <span class="odd-value">${match.away_odds.toFixed(2)}</span>
          </button>
        </div>
      </div>
    `).join('');
  } catch (error) {
    showToast('Failed to load matches', 'error');
  }
}

// Load bets
async function loadBets() {
  try {
    const data = await api.bets.getMyBets();
    if (data.bets.length === 0) {
      betsList.innerHTML = '<p style="color: var(--text-muted); text-align: center;">No bets placed yet</p>';
      return;
    }

    betsList.innerHTML = data.bets.map(bet => `
      <div class="bet-card">
        <div class="bet-header">
          <span class="bet-match">${bet.home_team} vs ${bet.away_team}</span>
          <span class="bet-status ${bet.status}">${bet.status.toUpperCase()}</span>
        </div>
        <div class="bet-details">
          <div class="bet-detail">
            <span class="bet-detail-label">Selection</span>
            <span class="bet-detail-value">${bet.selection.toUpperCase()}</span>
          </div>
          <div class="bet-detail">
            <span class="bet-detail-label">Amount</span>
            <span class="bet-detail-value">$${bet.amount.toFixed(2)}</span>
          </div>
          <div class="bet-detail">
            <span class="bet-detail-label">Odds</span>
            <span class="bet-detail-value">${bet.odds.toFixed(2)}</span>
          </div>
          <div class="bet-detail">
            <span class="bet-detail-label">Potential Payout</span>
            <span class="bet-detail-value">$${bet.potential_payout.toFixed(2)}</span>
          </div>
        </div>
      </div>
    `).join('');
  } catch (error) {
    showToast('Failed to load bets', 'error');
  }
}

// Bet modal functions
function openBetModal(matchId, selection, odds) {
  currentMatch = { id: matchId, selection, odds };

  // Get match details
  api.matches.getById(matchId).then(data => {
    document.getElementById('betDetails').innerHTML = `
      <p><strong>${data.match.home_team} vs ${data.match.away_team}</strong></p>
      <p>Selection: ${selection.toUpperCase()}</p>
    `;
  });

  document.getElementById('betSelection').value = selection;
  document.getElementById('betOdds').textContent = odds.toFixed(2);
  document.getElementById('betPayout').textContent = '0.00';
  betModal.classList.remove('hidden');
}

function closeBetModal() {
  betModal.classList.add('hidden');
  currentMatch = null;
}

// Bet form submission
async function handleBet(e) {
  e.preventDefault();
  const amount = parseFloat(document.getElementById('betAmount').value);

  if (amount > currentUser.balance) {
    showToast('Insufficient balance', 'error');
    return;
  }

  try {
    const data = await api.bets.place(currentMatch.id, currentMatch.selection, amount);
    currentUser.balance = data.newBalance;
    document.getElementById('balanceDisplay').textContent = currentUser.balance.toFixed(2);
    localStorage.setItem('user', JSON.stringify(currentUser));
    showToast('Bet placed successfully!');
    closeBetModal();
    loadBets();
  } catch (error) {
    showToast(error.message, 'error');
  }
}

// Update bet preview
document.getElementById('betAmount').addEventListener('input', (e) => {
  const amount = parseFloat(e.target.value) || 0;
  const payout = amount * currentMatch.odds;
  document.getElementById('betPayout').textContent = payout.toFixed(2);
});

// Tab switching
document.querySelectorAll('.tab-btn').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');

    if (btn.dataset.tab === 'login') {
      loginForm.classList.remove('hidden');
      registerForm.classList.add('hidden');
    } else {
      loginForm.classList.add('hidden');
      registerForm.classList.remove('hidden');
    }
  });
});

document.getElementById('showRegister').addEventListener('click', (e) => {
  e.preventDefault();
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.querySelector('[data-tab="register"]').classList.add('active');
  loginForm.classList.add('hidden');
  registerForm.classList.remove('hidden');
});

document.getElementById('showLogin').addEventListener('click', (e) => {
  e.preventDefault();
  document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
  document.querySelector('[data-tab="login"]').classList.add('active');
  registerForm.classList.add('hidden');
  loginForm.classList.remove('hidden');
});

// Modal close handlers
document.querySelector('.close-btn').addEventListener('click', closeBetModal);
betModal.addEventListener('click', (e) => {
  if (e.target === betModal) closeBetModal();
});

// Event listeners
loginForm.addEventListener('submit', handleLogin);
registerForm.addEventListener('submit', handleRegister);
document.getElementById('betForm').addEventListener('submit', handleBet);

// Initialize
function init() {
  const storedToken = localStorage.getItem('token');
  const storedUser = localStorage.getItem('user');

  if (storedToken && storedUser) {
    currentToken = storedToken;
    currentUser = JSON.parse(storedUser);
    updateUI();
  }
}

init();
