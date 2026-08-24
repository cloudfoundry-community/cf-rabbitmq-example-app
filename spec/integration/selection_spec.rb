require 'spec_helper'
require 'integration_helper'
require 'app'

# Amendment 5: prove the rmq_protocol cookie and ?protocol= param actually
# change which protocol backs the bare routes, against a live broker -
# not just that a cookie gets set (that's already covered by the unit
# suite's spec/unit/index_spec.rb).
#
# 'management' is the sharpest live signal available: Adapters::Management
# doesn't implement declare/publish/consume, so it inherits Base's 501
# NOT-SUPPORTED. The bare routes only ever produce that 501 when
# selection has actually swapped the backing adapter away from AMQP - a
# cosmetic-only selection (cookie set, but bare routes still secretly
# AMQP) would keep returning AMQP's normal 201/200/404 instead.
RSpec.describe 'protocol selection against a live broker', :integration do
  def app
    Sinatra::Application
  end

  before { ENV['VCAP_SERVICES'] = integration_vcap }

  it 'defaults the bare routes to AMQP with no selection' do
    get "/queue/#{itest_queue('select-default')}"
    expect(last_response.status).to eq(404) # AMQP: QueueNotFound
  end

  it 'remaps the bare routes via the ?protocol= query param' do
    get "/queue/#{itest_queue('select-param')}?protocol=management"
    expect(last_response.status).to eq(501)
    expect(last_response.body).to eq('NOT-SUPPORTED: consume over management')
  end

  it 'remaps the bare routes via the rmq_protocol cookie' do
    post '/select', protocol: 'management'
    expect(last_response.status).to eq(302)

    # Rack::Test carries Set-Cookie forward automatically within the same
    # session, so this next request is the live proof the cookie (not
    # just the redirect) is what changed the backing protocol.
    get "/queue/#{itest_queue('select-cookie')}"
    expect(last_response.status).to eq(501)
    expect(last_response.body).to eq('NOT-SUPPORTED: consume over management')
  end

  it 'lets a per-request param override a standing cookie selection' do
    post '/select', protocol: 'management'
    expect(last_response.status).to eq(302)

    get "/queue/#{itest_queue('select-override')}?protocol=amqp"
    expect(last_response.status).to eq(404) # back to AMQP for this one request
  end
end
