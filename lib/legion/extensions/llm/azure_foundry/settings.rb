# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Settings
          DEFAULT = {
            discovery: {
              interval_seconds: 3600, request_timeout: 10, open_timeout: 5,
              health_timeout: 5, health_open_timeout: 3, max_pages: 100
            },
            instance: {
              endpoint: nil, tier: :cloud, transport: :http,
              credentials: { api_key: nil, bearer_token: nil, broker: nil,
                             project_bearer_token: nil, project_broker: nil },
              provider: {
                api_version: '2024-05-01-preview', surface: :model_inference,
                project_endpoint: nil, project_api_version: 'v1', project_connection_name: nil
              },
              usage: { inference: true, embedding: true, image: false },
              limits: { concurrency: 4 },
              fleet: { enabled: false, respond_to_requests: false, capabilities: %i[chat stream_chat embed tools] }
            }
          }.freeze
        end
      end
    end
  end
end
