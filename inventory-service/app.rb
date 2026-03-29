require 'sinatra'
require 'sinatra/json'
require 'sqlite3'
require 'json'

set :port, 4001
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

def db
  @db ||= begin
    db = SQLite3::Database.new('inventory.db')
    db.results_as_hash = true
    db.execute <<-SQL
      CREATE TABLE IF NOT EXISTS products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        price REAL NOT NULL,
        stock INTEGER NOT NULL DEFAULT 0
      );
    SQL
    db
  end
end

get '/products' do
  json db.execute('SELECT * FROM products')
end

get '/products/:id' do
  product = db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Product not found') unless product
  json product
end

post '/products' do
  data = JSON.parse(request.body.read)
  db.execute('INSERT INTO products (name, price, stock) VALUES (?, ?, ?)',
             [data['name'], data['price'], data['stock'] || 0])
  id = db.last_insert_row_id
  json db.execute('SELECT * FROM products WHERE id = ?', id).first
end

patch '/products/:id/stock' do
  data = JSON.parse(request.body.read)
  product = db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Product not found') unless product

  new_stock = product['stock'] + data['quantity']
  halt 422, json(error: 'wont place the order') if new_stock < 0

  db.execute('UPDATE products SET stock = ? WHERE id = ?', [new_stock, params[:id]])
  json db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
end

get '/products/:id/availability' do
  product = db.execute('SELECT * FROM products WHERE id = ?', params[:id]).first
  halt 404, json(error: 'Product not found') unless product

  quantity = (params[:quantity] || 1).to_i
  json(available: product['stock'] >= quantity, stock: product['stock'])
end
