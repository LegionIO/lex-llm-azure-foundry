# frozen_string_literal: true

# A scoped identity issuer behind the real host Broker/LeaseRenewer. No token
# network calls are needed to exercise the consumer's lease refresh behavior.
class AzureBrokerIssuer
  attr_accessor :lease

  def initialize(lease:)
    @lease = lease
  end

  def provide_token = lease
end
