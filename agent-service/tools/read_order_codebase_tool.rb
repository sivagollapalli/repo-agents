require 'agents'

class ReadOrderCodebaseTool < Agents::Tool
  description "Reads the order service source code (app.rb) to understand endpoints, logic, and database schema"

  def perform(_tool_context)
    File.read(File.expand_path('../../order-service/app.rb', __dir__))
  rescue => e
    "Error reading order service code: #{e.message}"
  end
end
