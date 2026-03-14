require 'json'
require 'securerandom'
require 'fileutils'

# Shared memory module for cross-service session management.
# Each session is a JSON file in the shared-memory directory.
#
# Session JSON schema:
# {
#   "session_id": "uuid",
#   "created_at": "iso8601",
#   "updated_at": "iso8601",
#   "entries": [
#     {
#       "agent": "orchestrator|order-service|inventory-service|user",
#       "type": "question|answer|analysis|routing",
#       "content": "the message content",
#       "timestamp": "iso8601"
#     }
#   ]
# }
module SharedMemory
  MEMORY_DIR = File.expand_path(File.join(__dir__))

  def self.session_path(session_id)
    File.join(MEMORY_DIR, "#{session_id}.json")
  end

  # Create a new session, returns session_id
  def self.create_session
    session_id = SecureRandom.uuid
    now = Time.now.utc.iso8601
    data = {
      session_id: session_id,
      created_at: now,
      updated_at: now,
      entries: []
    }
    File.write(session_path(session_id), JSON.pretty_generate(data))
    session_id
  end

  # Load a session, returns nil if not found
  def self.load_session(session_id)
    path = session_path(session_id)
    return nil unless File.exist?(path)
    JSON.parse(File.read(path))
  end

  # Append an entry to the session
  # agent: "orchestrator", "order-service", "inventory-service", "user"
  # type: "question", "answer", "analysis", "routing"
  # content: string
  def self.append(session_id, agent:, type:, content:)
    path = session_path(session_id)
    data = JSON.parse(File.read(path))
    data['entries'] << {
      'agent' => agent,
      'type' => type,
      'content' => content,
      'timestamp' => Time.now.utc.iso8601
    }
    data['updated_at'] = Time.now.utc.iso8601
    File.write(path, JSON.pretty_generate(data))
    data
  end

  # Format entries as conversation context for LLM
  def self.conversation_context(session_id)
    data = load_session(session_id)
    return "" unless data && data['entries'].any?

    lines = data['entries'].map do |e|
      "[#{e['agent']}] (#{e['type']}): #{e['content']}"
    end
    lines.join("\n\n")
  end
end
