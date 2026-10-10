# Food Delivery Backend (Dart + MongoDB, microservices)

## Run
    cp .env.example .env      # edit secrets
    docker compose up --build
    # API gateway: http://localhost:8080

## Services
| Service | Routes |
|---|---|
| auth | POST /auth/register, /auth/login, GET /auth/me |
| order | GET/POST /restaurants, POST /orders, GET /orders, GET /orders/:id, POST /orders/:id/accept, PATCH /orders/:id/status |
| payment | POST /payments, GET /payments/:id, POST /payments/webhook |
| location | POST /drivers/location, GET /drivers/nearby, WS /ws/driver, WS /ws/track/:orderId |

Order flow: pending_payment -> paid -> preparing -> ready -> picked_up -> delivered

## Quick test
    curl -X POST localhost:8080/auth/register -H 'content-type: application/json' \
      -d '{"name":"Dara","email":"dara@test.com","password":"password123","role":"customer"}'
