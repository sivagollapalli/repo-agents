# Microservices: Inventory + Order

Two Sinatra microservices with SQLite databases.

## Start Services

```bash
# Terminal 1 — Inventory Service (port 4001)
cd inventory-service && bundle exec ruby app.rb

# Terminal 2 — Order Service (port 4002)
cd order-service && bundle exec ruby app.rb
```

## Usage

### Add a product
```bash
curl -X POST http://localhost:4001/products \
  -H 'Content-Type: application/json' \
  -d '{"name": "Widget", "price": 9.99, "stock": 100}'
```

### List products
```bash
curl http://localhost:4001/products
```

### Place an order
```bash
curl -X POST http://localhost:4002/orders \
  -H 'Content-Type: application/json' \
  -d '{"product_id": 1, "quantity": 3}'
```

### List orders
```bash
curl http://localhost:4002/orders
```
