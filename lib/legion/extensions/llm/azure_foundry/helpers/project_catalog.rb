# frozen_string_literal: true

require 'uri'
require 'legion/extensions/llm/azure_foundry/deployment_catalog_parser'

module Legion
  module Extensions
    module Llm
      module AzureFoundry
        module Helpers
          # Azure deployment transport; publication stays in Discovery::Pipeline.
          module ProjectCatalog
            private

            def fetch_project_deployments(instance_cfg:)
              endpoint = project_catalog_endpoint(instance_cfg: instance_cfg)
              conn = project_connection(instance_cfg: instance_cfg, endpoint: endpoint)
              version = instance_cfg[:azure_foundry_project_api_version] ||
                        Legion::Extensions::Llm::AzureFoundry::Settings::DEFAULT[:instance][:provider][:project_api_version]
              initial = URI("#{endpoint}/deployments?#{URI.encode_www_form('api-version' => version)}")
              project_catalog_pages(connection: conn, initial: initial)
            end

            def project_connection(instance_cfg:, endpoint:)
              token = instance_cfg[:azure_foundry_project_bearer_token]
              unless credential_string?(token)
                raise Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure,
                      'Azure project deployment discovery requires credentials.project_bearer_token ' \
                      'with the ai.azure.com scope'
              end

              config = instance_cfg.except(:azure_foundry_api_key, :azure_foundry_bearer_token)
                                   .merge(azure_foundry_bearer_token: token)
              limits = settings[:discovery]
              build_connection(base_url: endpoint, instance_cfg: config,
                               timeout: limits[:request_timeout], open_timeout: limits[:open_timeout])
            end

            def project_catalog_endpoint(instance_cfg:)
              uri = URI.parse(instance_cfg.fetch(:azure_foundry_project_endpoint))
              unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
                raise Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure,
                      'provider.project_endpoint must be an absolute project URL ' \
                      'without credentials, query, or fragment'
              end

              uri.to_s.sub(%r{/+\z}, '')
            end

            def project_catalog_pages(connection:, initial:)
              page = initial
              entries = []
              visited = Set.new
              settings[:discovery][:max_pages].times do
                result = read_project_page(connection: connection, page: page, visited: visited)
                entries.concat(result[:entries])
                unless result[:next_link]
                  return Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser.dedupe_by_model_id(entries)
                end

                page = next_project_page(initial: initial, next_link: result[:next_link])
              end
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'Azure deployment pagination exceeded discovery.max_pages'
            end

            def read_project_page(connection:, page:, visited:)
              unless visited.add?(page.to_s)
                raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                      'Azure deployment pagination cycle'
              end

              response = connection.get(page.to_s)
              unless response.status == 200
                raise Legion::Extensions::Llm::Discovery::Pipeline::CatalogFetchFailure,
                      "deployment catalog fetch returned HTTP #{response.status}"
              end
              Legion::Extensions::Llm::AzureFoundry::DeploymentCatalogParser.page(body: catalog_body(response))
            end

            def next_project_page(initial:, next_link:)
              page = URI.join(initial.to_s, next_link)
              unless same_project_endpoint?(initial: initial, page: page)
                raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                      'Azure deployment nextLink must remain on the same project deployment endpoint'
              end

              page
            rescue URI::InvalidURIError => e
              raise Legion::Extensions::Llm::AzureFoundry::ModelCatalogParser::InvalidCatalog,
                    'Azure deployment nextLink is not a valid URL', cause: e
            end

            def same_project_endpoint?(initial:, page:)
              [page.scheme, page.host, page.port, page.path] ==
                [initial.scheme, initial.host, initial.port, initial.path] && !page.userinfo && !page.fragment
            end
          end
        end
      end
    end
  end
end
