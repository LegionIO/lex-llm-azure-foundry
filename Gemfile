# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

group :development do
  gem 'bundler', '>= 2.0'
  gem 'rake', '>= 13.0'
  gem 'rspec', '~> 3.12'
  gem 'rubocop', '>= 1.0'
  gem 'rubocop-performance'
  gem 'rubocop-rake', '>= 0.6'
  gem 'rubocop-rspec'
end

group :test do
  # Broker integration is exercised against the actual host lease service.
  legionio_path = File.expand_path('../../LegionIO', __dir__)
  legionio_options = File.directory?(legionio_path) ? { path: legionio_path } : {}
  gem 'legionio', **legionio_options

  # The published lex-llm (>= 0.8.0, declared in the gemspec) provides the
  # WeightSchema/WeightReconciler and Canonical types these specs require.
  # Use the local checkout when present (development); CI resolves the
  # published gem via the gemspec dependency.
  lex_llm_path = File.expand_path('../lex-llm', __dir__)
  gem 'lex-llm', path: lex_llm_path if Dir.exist?(lex_llm_path)
end
