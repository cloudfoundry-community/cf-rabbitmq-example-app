# Read-only. Queue depth here is what the rabbitmq-autoscale kit feature
# scales on, and nothing in the previous example apps exposed it.
#
# /mgmt/* is the documented short alias; /management/* also exists from
# the protocol-prefixed loop in lib/routes/protocol.rb. Both are
# intentional - see the design notes on issue #96 - and neither redirects
# to the other.
get '/mgmt/ping' do
  content_type :json
  status 200
  body JSON.pretty_generate(management.overview)
end

get '/mgmt/queues' do
  content_type :json
  status 200
  body JSON.pretty_generate(management.queues)
end

get '/mgmt/queue/:name' do
  queue = management.queue(params[:name])
  halt 404, 'NO-SUCH-QUEUE' if queue.nil?

  content_type :json
  status 200
  body JSON.pretty_generate(queue)
end
