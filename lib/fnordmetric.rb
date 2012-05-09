require "eventmachine"
require 'em-hiredis'
require 'redis'
require "active_support/core_ext"
require 'yajl'
require 'sinatra/base'
require 'haml'
require 'rack/server'

require "fnordmetric/ext"
require "fnordmetric/version"


# TODO
#  -> timeline-widget: tick button active states
#  -> port numbers style from scala-experiment
#  -> gauge api: render with add. offset
#  -> toplist-widget: tick+range selector
#  -> toplist-widget: display trends
#  -> timeline-widget: compare with yesterday
#  -> numeric-gauge view: add numbers
#  -> store per-session-data
#  -> callback on session-flush
#  -> backport sidebar css from 0.7?
#  -> minimize/pack js
#  -> put images into one sprite
#  -> remove params from log
#  -> toplist_widget per_keyword: show multiple keywords
#  -> proper garbage collection
#  -> gauge overview page (a'la github graphs landing)
#  -> gauge online vs offline status
#
# numeric_gauge
#   -> time-distribution/punchcard
#   -> moving avg. etc / bezier fu
#   -> realtime view
#   -> formatter: num, time, currency
#   -> opts: average, average_by, unique_by, enable_histogram, enable_punchard, enable_stddeviation
#
# toplist_gauge
#   -> trending keys
#
# timeline_widget
#   -> show last interval (cmp. w/ yesterday)
#
# toplist_widget
#   -> multi-interval + range-selector
#
# geo_distribution_gauge
#
#
# wiki
#
#  -> getting started
#  -> gagues pages
#  -> sending data pages
#    -> tcp, udp, http, apis
#    -> events containing user data
#    -> pre-defined fields (_session etc)
#    -> pre-defined events (_incr, _observe etc)
#  -> configurin fnordmetric
#    -> configuration options
#    -> running embedded
#    -> running standalone
#  -> event handler pages
#    -> pre-defined event-fields
#    -> incrementing multiple gauges per event
#    -> storing data per session
#    -> end-of-session callback
#  -> building custom dashboards

module FnordMetric

  @@namespaces = {}
  @@server_configuration = nil

  @@chan_feed     = EM::Channel.new
  @@chan_upstream = EM::Channel.new

  def self.chan_feed
    @@chan_feed 
  end

  def self.chan_upstream
    @@chan_upstream 
  end

  def self.namespace(key=nil, &block)
    @@namespaces[key] = block
  end

  def self.server_configuration=(configuration)
    @@server_configuration = configuration
  end

  def self.default_options(opts = {})
    {
      :redis_url => "redis://localhost:6379",
      :redis_prefix => "fnordmetric",
      :inbound_stream => ["0.0.0.0", "1337"],
      :inbound_protocol => :tcp,
      :web_interface => ["0.0.0.0", "4242"],
      :web_interface_server => "thin",
      :start_worker => true,
      :print_stats => 3,
      :event_queue_ttl => 120,
      :event_data_ttl => 3600*24*30,
      :session_data_ttl => 3600*24*30
    }.merge(opts)
  end

  def self.options(opts = {})
    default_options(@@server_configuration || {}).merge(opts)
  end

  def self.start_em(opts = {})
    EM.run do

      trap("TERM", &method(:shutdown))
      trap("INT",  &method(:shutdown))

      opts = options(opts)
      app = embedded(opts)

      @backend = FnordMetric::RedisBackend.new(opts)

      if opts[:web_interface]
        server = opts[:web_interface_server].downcase

        unless ["thin", "hatetepe"].include? server
          raise "Need an EventMachine webserver, but #{server} isn't"
        end

        host, port = *opts[:web_interface]

        Rack::Server.start(
          :app => app,
          :server => server,
          :Host => host, 
          :Port => port
        ) && log("listening on http://#{host}:#{port}")
        
        FnordMetric::WebSocket.new(
          :host => host, 
          :port => (port.to_i+1),
          :chan_upstream => @chan_upstream,
          :chan_feed => @chan_feed
        ) && log("listening on ws://#{host}:#{port.to_i+1}")

      end
    end
  end

  def self.log(msg)
    puts "[#{Time.now.strftime("%y-%m-%d %H:%M:%S")}] #{msg}"
  end

  def self.error!(msg)
    raise msg if ENV['FNORDMETRIC_ENV'] == 'test'
    puts(msg); exit!
  end

  def self.run
    start_em
  rescue Exception => e
    raise e
    log "!!! eventmachine died, restarting... #{e.message}"
    sleep(1); run
  end

  def self.shutdown
    log "shutting down, byebye"
    EM.stop
  end

  def self.connect_redis(redis_url)
    EM::Hiredis.connect(redis_url)
  end

  def self.print_stats(opts, redis) # FIXME: refactor this mess
    keys = [:events_received, :events_processed]
    redis.llen("#{opts[:redis_prefix]}-queue") do |queue_length|
      redis.hmget("#{opts[:redis_prefix]}-stats", *keys) do |data|
        data_human = keys.size.times.map{|n|"#{keys[n]}: #{data[n]}"}
        log "#{data_human.join(", ")}, queue_length: #{queue_length}"
      end
    end
  end

  def self.standalone
    require "fnordmetric/logger"
    require "fnordmetric/standalone"
  end

  # returns a Rack app which can be mounted under any path.
  # `:start_worker`   starts a worker
  # `:inbound_stream` starts the TCP interface
  # `:print_stats`    periodicaly prints worker stats
  def self.embedded(opts={})
    opts = options(opts)
    app  = nil

    if opts[:rack_app] or opts[:web_interface]
      app = FnordMetric::App.new(@@namespaces.clone, opts)
    end

    EM.next_tick do
      if opts[:start_worker]
        worker = Worker.new(@@namespaces.clone, opts)
        worker.ready!
      end

      if opts[:inbound_stream]
        inbound_class = opts[:inbound_protocol] == :udp ? InboundDatagram : InboundStream
        begin
          inbound_stream = inbound_class.start(opts)
          log "listening on #{opts[:inbound_protocol]}://#{opts[:inbound_stream][0..1].join(":")}"
        rescue
          log "cant start #{inbound_class.name}. port in use?"
        end
      end

      if opts[:print_stats]
        redis = connect_redis(opts[:redis_url])
        EM::PeriodicTimer.new(opts[:print_stats]) do
          print_stats(opts, redis)
        end
      end
    end

    app
  end

end


require "fnordmetric/backends/redis_backend"

require "fnordmetric/api"
require "fnordmetric/udp_client"
require "fnordmetric/inbound_stream"
require "fnordmetric/inbound_datagram"
require "fnordmetric/worker"
require "fnordmetric/widget"
require "fnordmetric/timeline_widget"
require "fnordmetric/numbers_widget"
require "fnordmetric/bars_widget"
require "fnordmetric/toplist_widget"
require "fnordmetric/pie_widget"
require "fnordmetric/html_widget"
require "fnordmetric/namespace"
require "fnordmetric/gauge_modifiers"
require "fnordmetric/gauge_calculations"
require "fnordmetric/context"
require "fnordmetric/gauge"
require "fnordmetric/remote_gauge"
require "fnordmetric/multi_gauge"
require "fnordmetric/numeric_gauge"
require "fnordmetric/toplist_gauge"
require "fnordmetric/session"
require "fnordmetric/app"
require "fnordmetric/websocket"
require "fnordmetric/dashboard"
require "fnordmetric/event"
