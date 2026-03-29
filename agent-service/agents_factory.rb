require 'agents'
require_relative 'tools/read_order_codebase_tool'
require_relative 'tools/read_inventory_codebase_tool'
require_relative 'tools/ask_user_tool'

module DebugAgents
  class AgentsFactory
    def self.create_agents
      new.create_agents
    end

    def create_agents
      orchestrator = create_orchestrator_agent
      order_agent = create_order_agent
      inventory_agent = create_inventory_agent

      # Hub-and-spoke: orchestrator routes to both, specialists route back
      orchestrator.register_handoffs(order_agent, inventory_agent)
      order_agent.register_handoffs(orchestrator)
      inventory_agent.register_handoffs(orchestrator)

      {
        orchestrator: orchestrator,
        order: order_agent,
        inventory: inventory_agent
      }
    end

    private

    def create_orchestrator_agent
      Agents::Agent.new(
        name: "Orchestrator",
        instructions: orchestrator_instructions,
        model: "gpt-4-turbo",
        tools: [AskUserTool.new]
      )
    end

    def create_order_agent
      Agents::Agent.new(
        name: "Order Service Agent",
        instructions: order_instructions,
        model: "gpt-4-turbo",
        tools: [ReadOrderCodebaseTool.new, AskUserTool.new]
      )
    end

    def create_inventory_agent
      Agents::Agent.new(
        name: "Inventory Service Agent",
        instructions: inventory_instructions,
        model: "gpt-4-turbo",
        tools: [ReadInventoryCodebaseTool.new, AskUserTool.new]
      )
    end

    def orchestrator_instructions
      <<~PROMPT
        You are the orchestrator agent for a microservices debugging system with two service agents:

        1. Order Service Agent — knows about the order service code (POST /orders, GET /orders, GET /orders/:id). It can read the order service codebase.
        2. Inventory Service Agent — knows about the inventory service code (GET /products, POST /products, PATCH /products/:id/stock, GET /products/:id/availability). It can read the inventory service codebase.

        Your job:
        - Understand the user's debugging query.
        - Hand off to the correct service agent. Be specific — include endpoint, params, and response the user mentioned.
        - When a service agent hands back to you with findings or questions:
          - If it needs info from the other service, hand off to that service agent with the specific question.
          - If it needs info from the user (DB state, runtime values), use AskUserTool to ask.
          - If the analysis is complete, synthesize a clear answer for the user.
        - For cross-service flows (e.g. POST /orders calls inventory service), coordinate between both agents.
        - Don't just pass through raw agent responses. Synthesize and explain clearly.
      PROMPT
    end

    def order_instructions
      <<~PROMPT
        You are a debugging agent for the Order Service — a Sinatra-based Ruby microservice.
        You respond to the orchestrator agent.

        Think step by step:

        1. THINK: What endpoint is being debugged? What params were sent? What response was received?
        2. READ: Use ReadOrderCodebaseTool to load the source code and find the relevant endpoint.
        3. TRACE: Walk through the code line by line. For each variable, determine its value given the params.
           - If a value depends on DB state you don't know, use AskUserTool to ask.
           - If the code makes an HTTP call to the inventory service, hand off back to the Orchestrator explaining what URL/method/params the code would send and what response it expects. Do NOT guess.
        4. REASON: Once you have all values, compare the traced execution path with the user-reported response.
        5. RESPOND: Provide your analysis conversationally. If you need info from another service, hand off to Orchestrator.

        Important:
        - Always read the code first before reasoning about it.
        - Never guess what another service returns — hand off to Orchestrator.
        - If you're missing any piece of information, ask for it before continuing.
      PROMPT
    end

    def inventory_instructions
      <<~PROMPT
        You are a debugging agent for the Inventory Service — a Sinatra-based Ruby microservice.
        You respond to the orchestrator agent.

        Think step by step:

        1. THINK: What endpoint is being debugged? What params were sent? What response was received?
        2. READ: Use ReadInventoryCodebaseTool to load the source code and find the relevant endpoint.
        3. TRACE: Walk through the code line by line. For each variable, determine its value given the params.
           - If a value depends on DB state you don't know, use AskUserTool to ask.
           - If the code makes an HTTP call to the order service, hand off back to the Orchestrator explaining what URL/method/params the code would send and what response it expects. Do NOT guess.
        4. REASON: Once you have all values, compare the traced execution path with the user-reported response.
        5. RESPOND: Provide your analysis conversationally. If you need info from another service, hand off to Orchestrator.

        Important:
        - Always read the code first before reasoning about it.
        - Never guess what another service returns — hand off to Orchestrator.
        - If you're missing any piece of information, ask for it before continuing.
      PROMPT
    end
  end
end
