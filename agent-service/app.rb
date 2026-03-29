require 'sinatra'
require 'sinatra/json'
require 'json'
require 'securerandom'
require 'agents'
require_relative '../shared-memory/session'
require_relative 'agents_factory'

set :port, 4000
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

Agents.configure do |config|
  config.openai_api_key = ENV.fetch('OPENAI_API_KEY', nil)
  config.default_model = 'gpt-4-turbo'
  config.debug = true
end

# Create agents and runner once at boot
AGENTS = DebugAgents::AgentsFactory.create_agents
RUNNER = Agents::Runner.with_agents(
  AGENTS[:orchestrator],
  AGENTS[:order],
  AGENTS[:inventory]
)

post '/agent' do
  data = JSON.parse(request.body.read)
  prompt = data['prompt']
  halt 400, json(error: 'prompt is required') unless prompt && !prompt.strip.empty?

  # Create or load session
  session_id = data['session_id']
  if session_id
    session = SharedMemory.load_session(session_id)
    halt 404, json(error: 'session not found') unless session
  else
    session_id = SharedMemory.create_session
  end

  # Record user message
  SharedMemory.append(session_id, agent: 'user', type: 'question', content: prompt)

  # Build context from shared memory for conversation continuity
  # Deep symbolize keys — the framework expects symbol keys throughout
  session_data = SharedMemory.load_session(session_id)
  context = (session_data && session_data['context']) || {}
  context = JSON.parse(JSON.generate(context), symbolize_names: true) if context.is_a?(Hash)

  # Run the multi-agent workflow
  result = RUNNER.run(prompt, context: context)

  logger.info "Runner result: output=#{result.output.inspect}, error=#{result.error.inspect}, messages_count=#{result.messages&.length}"

  # Save the updated context back to shared memory for next turn
  updated_session = SharedMemory.load_session(session_id)
  updated_session['context'] = result.context if result.respond_to?(:context)
  File.write(SharedMemory.session_path(session_id), JSON.pretty_generate(updated_session))

  # Extract output — handle errors and nil output gracefully
  if result.error
    output = result.error.backtrace
  elsif result.output.nil?
    last_msg = result.messages&.reverse&.find { |m| m[:role].to_s == 'assistant' && m[:content] }
    output = last_msg ? last_msg[:content] : "[No output - check agent logs]"
  else
    output = result.output
  end

  json({ session_id: session_id, response: output })
rescue => e
  logger.error "Agent error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
  status 500
  json({ error: e.message })
end
