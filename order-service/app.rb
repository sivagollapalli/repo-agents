require 'sinatra'
require 'sinatra/json'
require 'sqlite3'
require 'net/http'
require 'json'

set :port, 4002
set :bind, '0.0.0.0'
set :logging, true

before do
  if request.request_method != 'GET'
    request.body.rewind
    body = request.body.read
    request.body.rewind
    logger.info "[#{request.request_method}] #{request.path_info} params=#{body}"
  else
    logger.info "[GET] #{request.path_info} params=#{params}"
  end
end

INVENTORY_URL = ENV.fetch('INVENTORY_URL', 'http://localhost:4001')

def db
  @db ||= begin
    db = SQLite3::Database.new('orders.db')
    db.results_as_hash = true
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS orders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        product_id INTEGER NOT NULL,
        quantity INTEGER NOT NULL,
        total_price REAL NOT NULL,
        status TEXT NOT NULL DEFAULT 'confirmed',
        created_at TEXT NOT NULL DEFAULT (datetime('now'))
      );
    SQL
    db
  end
end

def inventory_get(path)
  uri = URI("#{INVENTORY_URL}#{path}")
  response = Net::HTTP.get_response(uri)
  [response.code.to_i, JSON.parse(response.body)]
rescue StandardError => e
  [503, { 'error' => "Inventory service unavailable: #{e.message}" }]
end

def inventory_patch(path, body)
  uri = URI("#{INVENTORY_URL}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  req = Net::HTTP::Patch.new(uri.path, 'Content-Type' => 'application/json')
  req.body = body.to_json
  response = http.request(req)
  [response.code.to_i, JSON.parse(response.body)]
rescue StandardError => e
  [503, { 'error' => "Inventory service unavailable: #{e.message}" }]
end

post '/orders' do
  data = JSON.parse(request.body.read)
  product_id = data['product_id']
  quantity = data['quantity'] || 1

  status, result = inventory_get("/products/#{product_id}/availability?quantity=#{quantity}")
  halt status, json(result) if status != 200
  halt 422, json(error: 'Wont able to place order') unless result['available']

  status, product = inventory_get("/products/#{product_id}")
  halt status, json(product) if status != 200

  status, deduct_result = inventory_patch("/products/#{product_id}/stock", { quantity: -quantity })
  halt status, json(deduct_result) if status != 200

  total = product['price'] * quantity
  db.execute('INSERT INTO orders (product_id, quantity, total_price) VALUES (?, ?, ?)',
             [product_id, quantity, total])
  order_id = db.last_insert_row_id
  json db.execute('SELECT * FROM orders WHERE id = ?', order_id).first
end

get '/orders' do
  json db.execute('SELECT * FROM orders')
end

get '/orders/:id' do
  order = db.execute('SELECT * FROM orders WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Order not found') unless order
  json order
end
