require 'spec_helper'
require 'integration_helper'
require 'app'

# Amendment 5: /mgmt/* including queue depth, against a live broker.
RSpec.describe '/mgmt routes against a live broker', :integration do
  def app
    Sinatra::Application
  end

  before { ENV['VCAP_SERVICES'] = integration_vcap }

  it '404s for a queue that was never declared' do
    get "/mgmt/queue/#{itest_queue('mgmt-absent')}"
    expect(last_response.status).to eq(404)
    expect(last_response.body).to eq('NO-SUCH-QUEUE')
  end

  it 'reports a freshly declared queue with zero depth' do
    name = itest_queue('mgmt-fresh')
    post '/queues', name: name
    expect(last_response.status).to eq(201)

    # A queue just created answers /mgmt/queue/:name with 200 straight
    # away, but the response omits stats fields like "messages" entirely
    # until the management plugin's stats collector has run at least once
    # for it - polling on status alone would see that gap as depth 0
    # rather than "not populated yet". Wait for the field itself to show
    # up, not just for a 200.
    depth = wait_until(message: "#{name} to gain a messages field in /mgmt/queue") do
      get "/mgmt/queue/#{name}"
      next nil unless last_response.status == 200

      body = JSON.parse(last_response.body)
      body.key?('messages') ? body : nil
    end

    expect(depth['name']).to eq(name)
    expect(depth['messages']).to eq(0)
  end

  it 'reports queue depth after publishing without consuming' do
    name = itest_queue('mgmt-depth')
    post '/queues', name: name
    expect(last_response.status).to eq(201)

    3.times do |i|
      put "/queue/#{name}", data: "message-#{i}"
      expect(last_response.status).to eq(201)
    end

    # The management plugin's stats collector updates on its own interval,
    # not synchronously with a publish - poll instead of assuming a fixed
    # delay is long enough (or short enough not to slow the suite down).
    queue = wait_until(timeout: 15, message: "#{name} depth to reach 3") do
      get "/mgmt/queue/#{name}"
      body = JSON.parse(last_response.body)
      body['messages'] == 3 ? body : nil
    end

    expect(queue['messages']).to eq(3)
  end
end
