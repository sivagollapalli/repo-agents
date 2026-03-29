require 'agents'

class ReadInventoryCodebaseTool < Agents::Tool
  description "Reads the inventory service source code (app.rb) to understand endpoints, logic, and database schema"

  def perform(_tool_context)
    File.read(File.expand_path('../../inventory-service/app.rb', __dir__))
  rescue => e
    "Error reading inventory service code: #{e.message}"
  end
end
