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
  # The published lex-llm (>= 0.7.6, declared in the gemspec) provides the
  # WeightSchema/WeightReconciler and Canonical types these specs require.
  # Use the local checkout when present (development); CI resolves the
  # published gem via the gemspec dependency.
  lex_llm_path = File.expand_path('../lex-llm', __dir__)
  gem 'lex-llm', path: lex_llm_path if Dir.exist?(lex_llm_path)
end
