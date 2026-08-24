require 'spec_helper'
require 'integration_helper'
require 'app'

# Amendment 5: the consistent-hash distribution actually spreading across
# bound queues, against a broker with rabbitmq_consistent_hash_exchange
# enabled. See exchange_type_spec.rb for the plugin-missing case
# (amendment 2).
RSpec.describe 'consistent hash exchange against a live broker', :integration do
  def app
    Sinatra::Application
  end

  before { ENV['VCAP_SERVICES'] = integration_vcap }

  it 'spreads messages across bound queues' do
    # RabbitMQ::ConsistentHash always names its queues consistent-hash-demo-0..N
    # (lib/rabbitmq/consistent_hash.rb is outside this task's scope, so
    # that naming can't be made run-unique the way the other specs' queue
    # names are). Against a broker left running from an earlier local run,
    # those queues - and any messages already sitting in them - persist.
    # Asserting a delta rather than an absolute total keeps this spec
    # honest on a fresh broker and on a reused one alike.
    get '/demo/consistent-hash'
    expect(last_response.status).to eq(200)
    baseline = JSON.parse(last_response.body)['total']

    post '/demo/consistent-hash', queues: 3, messages: 90
    expect(last_response.status).to eq(201)

    body = wait_until(timeout: 15, message: 'consistent-hash distribution to grow by 90') do
      get '/demo/consistent-hash'
      next nil unless last_response.status == 200

      parsed = JSON.parse(last_response.body)
      (parsed['total'] - baseline) == 90 ? parsed : nil
    end

    expect(body['total'] - baseline).to eq(90)
    expect(body['distribution'].keys.size).to eq(3)
    body['distribution'].each_value { |count| expect(count).to be > 0 }
  end
end
