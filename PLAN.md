# Bet365 - Football Betting Website

## Project Assessment

### Complexity & Target Audience
- **Type**: Full-stack web application (FE + BE)
- **Target Audience**: Football/sports fans who want to place bets on matches
- **Complexity Level**: Medium - requires user authentication, match data management, betting logic, and real-time updates

### Core Features
1. User registration and authentication
2. Browse football matches (live and upcoming)
3. View betting odds for different outcomes
4. Place bets on matches
5. View betting history and wallet balance
6. Admin panel for managing matches and odds

## Tech Stack & Architecture

### Architecture: Single-Service (Monolith)
Given the project scope, a single-service architecture is appropriate:
- One Docker container with both frontend and backend
- Simpler deployment and maintenance
- Suitable for MVP and early-stage development

### Technology Choices

| Component | Technology | Reason |
|-----------|------------|--------|
| Backend | Node.js + Express | Fast development, good ecosystem |
| Frontend | React (embedded via Express) | Component-based, popular |
| Database | SQLite (file-based) | No external dependencies, simple setup |
| Templating | EJS | Server-side rendering for simplicity |
| Styling | Tailwind CSS | Rapid UI development |

### Repository Structure

```
/tmp/source/
├── PLAN.md                          # This file
├── README.md                        # Project documentation
├── Dockerfile                       # Container definition
├── bootstrap.sh                     # GitOps bootstrap script
├── values.yaml                      # Deployment configuration
├── deployment.tpl.yaml              # K8s deployment template
├── azure-pipelines.yaml             # CI/CD pipeline
├── .gitignore                       # Git ignore patterns
├── package.json                     # Node.js dependencies
├── server.js                        # Main application entry
├── public/                          # Static assets
│   ├── index.html                   # Frontend entry
│   ├── css/
│   │   └── styles.css               # Custom styles
│   └── js/
│       └── app.js                   # Frontend logic
├── routes/                          # API routes
│   ├── auth.js                      # Authentication routes
│   ├── matches.js                   # Match data routes
│   ├── bets.js                      # Betting routes
│   └── admin.js                     # Admin routes
├── models/                          # Data models
│   ├── user.js                      # User model
│   ├── match.js                     # Match model
│   └── bet.js                       # Bet model
├── data/                            # SQLite database
│   └── bet365.db                    # Database file
└── views/                           # EJS templates
    └── home.ejs                     # Main page template
```

## DevOps Strategy

Based on the template knowledge:

### Deployment Mode: Single-Service
- One pipeline for the entire application
- Single K8s Deployment and Service

### CI/CD Flow
1. Developer commits to `develop` branch
2. Azure DevOps pipeline triggers
3. Docker image built and pushed to `registry-stag.imt-soft.com`
4. K8s manifest rendered via `envsubst`
5. `kubectl apply` deploys to `ai-team` namespace

### Key Configuration
- **Container Port**: 3000 (Express default)
- **Node Port**: 31850 (unique port in 31000-32000 range)
- **Health Check**: `/health` endpoint returning HTTP 200
- **Namespace**: `ai-team`
- **Replicas**: 1 (can scale based on traffic)

### Environment Variables
- `PORT` - Server port (default: 3000)
- `NODE_ENV` - Environment (development/production)

## Implementation Phases

1. **Phase 1**: Core backend API (authentication, matches, bets)
2. **Phase 2**: Frontend UI (responsive, user-friendly)
3. **Phase 3**: DevOps configuration (Dockerfile, values.yaml, etc.)
4. **Phase 4**: Testing and validation
