#!/usr/local/bin/ruby

# Rubygems must be first...
require 'rubygems'

# ...but we can sort the rest in string length order, descending!
require 'geoip_city'
require 'net/yail'
require 'open-uri'
require 'resolv'
require 'mysql'
require 'yaml'
require 'cgi'

# Replicates Hash#symbolize_keys from ActiveSupport
def deep_symbolize_keys!(h)
	keys = h.keys
	h.each do |k, v|
		h[k.to_sym] = h.delete(k) if k.is_a? String
		deep_symbolize_keys!(v) if v.is_a?(Hash)
	end
end

class GeoBot
	# You need the GeoCityLite daemon up and running for this to work.
	# Will fail horribly if it's not hanging around.
	
	GEO_DB = "/usr/local/share/GeoIP/GeoLiteCity.dat"
	
	def initialize(config_file)
		@config = YAML::load(File.open(config_file).read)
		deep_symbolize_keys!(@config)
		@geo = GeoIPCity::Database.new(GEO_DB, :index)
		@names, @requests, @logged_people = {}, {}, {}
		connect_db
	end
	
	def start
		@irc = Net::YAIL.new(@config[:server])
		setup_handlers
		irc_loop
	end
	
private

	def incoming_msg(fullactor, actor, target, text)
		log_actor(target, actor)
		if text.match(/^#{@irc.me}/i) then
			if m = (text.match(/.*?who is (in|from) (.*?)\??/i) || text.match(/.*?who do you know in (.*?)\??/i)) then
				lookup_people_by_place(actor, target, m)
			elsif text.match(/botsnack/i) then
				botsnack(actor)
			else
				lookup_by_nick(actor, target, text)
			end
		end
	end
	
	BOTSNACK_MSGS = ["We make good team!", "We must push little cart!", "I hear someone building diaper changing machine!", "WHO TOUCHED SASHA?"]
	def botsnack(actor)
		@irc.msg target, "#{actor}: om nom nom. om nom!"
		@irc.msg target, "#{BOTSNACK_MSGS[BOTSNACK_MSGS.length * rand]}"
	end
	
	def lookup_people_by_place(actor, target, m)
		country = m[m.length-1]
		country.strip!
		country.gsub!(/^the /i, "")
		
		people_list = find_people_in(target, country)
		people = people_list[0..10]
		names = ""
		if !people.empty? then
			last = people.pop
			if people.empty? then
				names = last
			else
				names = people.join(", ") + " and " + last
			end
		else
			names = "I don't know of anyone in #{country}!"
		end
		@irc.msg target, sprintf('%s: %s', actor, names)	
	end
	
	def lookup_by_nick(actor, target, text)
		text.gsub!(/\?$/, "")
		tokens = text.split(" ")
		go, who = false, nil
		go = true if text.match(/\b(where|who|locate)\b/i)
		tokens.reverse!
		tokens.each do |token|
			token.downcase!
			token.strip!
			who = token if @names[target] and @names[target].include? token
			break if go && who
		end
		if go and !who.nil? then
			@irc.raw "WHOIS #{who}"
			@requests[who.downcase] = {:from => actor, :on => target}			
		elsif go then
			m = text.match(/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/)
			if m then
				send_message_for_request(m[1], m[1], {:from => actor, :on => target})
			elsif m = text.match(/where is ([^\s]+)/i)
				who = m[1]
				@irc.raw "WHOIS #{who}"
				@requests[who.downcase] = {:from => actor, :on => target}
			else
				@irc.msg target, "I don't know who that is, #{actor}. Are they in this channel?"
			end
		end	
	end
	
	def irc_loop
		@irc.start_listening
		while true
			until @irc.dead_socket
				sleep 15
				@irc.handle(:irc_loop)
				Thread.pass
			end

			sleep 30			# Disconnected?  Wait a little while and start up again.
			@irc.stop_listening
			@irc.start_listening
		end
	end
	
	def setup_handlers
		@irc.prepend_handler :incoming_welcome, self.method(:join_channels)
		@irc.prepend_handler :incoming_msg, self.method(:incoming_msg)
		@irc.prepend_handler :incoming_join, self.method(:incoming_join)
		@irc.prepend_handler :incoming_part, self.method(:incoming_part)
		@irc.prepend_handler :incoming_namreply, self.method(:incoming_namreply)		
		@irc.prepend_handler :incoming_whoisuser, self.method(:incoming_whoisuser)
		@irc.prepend_handler :incoming_nosuchnick, self.method(:incoming_nosuchnick)
	end

	def connect_db
		@db = Mysql.new(
			@config[:database][:server], 
			@config[:database][:username], 
			@config[:database][:password], 
			@config[:database][:database]
		)
	end
	
	# Event handlers and crap
	
	def incoming_whoisuser(a, b)
		bits = a.split(" ")
		nick, host = bits[0], bits[2]
		rawnick = nick.dup
		clean_actor!(nick)
		if nick && host then
			request = @requests[nick]
			if request then
				send_message_for_request(host, rawnick, request)
				@requests.delete nick
			elsif request = @requests["$LOG-#{nick}"] then
				ip, result = lookup(host)
				if result then
					log(request[:on], request[:from], ip, result[:latitude], result[:longitude],
						 result[:city], result[:region], result[:country_name], result[:postal_code])
				end
				@requests.delete "$LOG-#{nick}"
			end
		end
	end
	
	def incoming_nosuchnick(a, b)
		nick = a.split(" ").first
		raw_nick = nick.dup
		clean_actor!(nick)
		request = @requests[nick]
		if request then
			send_message_for_request(nil, raw_nick, request)
			@requests.delete nick
		end
	end
	
	def incoming_part(fullactor, actor, target, text)
		clean_actor!(actor)
		@names[target] ||= []
		@names[target].delete actor
	end
	
	def incoming_join(fullactor, actor, target)
		clean_actor!(actor)
		log_actor(target, actor)
		@names[target] ||= []
		@names[target].push actor unless @names[target].include? actor
	end
	
	def incoming_namreply(str, full)
		chan, people = str.split(":", 2)
		channel = chan.split(" ")[1]
		people.split(" ").each do |person|
			clean_actor!(person)
			next if person.empty?
			@names[channel] ||= []
			@names[channel].push person unless @names[channel].include? person
		end
	end

	# And some utility methods
	def send_message_for_request(host, rawnick, request)
		msg = nil
		reply, map = location_for(host, rawnick)
		if map then
			msg = sprintf("%s: %s (Map: %s)", request[:from], reply, map)
		else
			msg = sprintf("%s: %s", request[:from], reply)
		end
		@irc.msg request[:on], msg	
	end

	def clean_actor!(actor)
		actor.downcase!
		actor.strip!
		actor.gsub!(/^[@+]/, "")
	end	

	def join_channels(text, args)
		if @config[:server][:auth] then
			@irc.msg @config[:server][:auth][:handler], "identify #{@config[:server][:auth][:password]}"
		end
		@config[:server][:channels].each do |channel|
			@irc.join channel
		end
		return false
	end
	
	def lookup(ip)
		begin
			ip = Resolv.getaddress(ip)
		rescue Resolv::ResolvError
			return nil
		end
		return ip, @geo.look_up(ip)
	end
	
	def location_for(ip, name = "that person")
		return "I don't know where #{name} is from!" if ip.nil?
		
		new_ip, result = lookup(ip)
		return "I don't know where #{name} is from! (Are they cloaked?)", nil if new_ip.nil?
		
		s, map = "", nil
		if result then
			result.delete(:region) if result[:region].match(/\d/)
			results = [result[:city], result[:region], result[:country_name]]
			s = "#{name} is in #{results.compact.join(", ")}"
			long_map = sprintf("http://maps.google.com/maps?f=q&hl=en&geocode=&q=%s+%s&ie=UTF8&ll=%s,%s&spn=0.202125,0.520477&z=12", result[:latitude], result[:longitude], result[:latitude], result[:longitude])
			map = open("http://is.gd/api.php?longurl=#{CGI::escape long_map}").read
		else
			s = "I don't know where #{name} is from!"
		end
		return s, map
	end
	
	def log_actor(channel, actor)
		key = sprintf("%s:%s:%s", @config[:server][:address], channel, actor)
		if !@logged_people[key] or @logged_people[key] < (Time.now - 3600).to_i then
			@logged_people[key] = Time.now.to_i
			@irc.raw "WHOIS #{actor}"
			@requests["$LOG-#{actor.downcase}"] = {:on => channel, :from => actor}			
		end
	end
	
	def find_people_in(channel, place)
		query = sprintf(
			'select distinct user from log where server = "%s" and channel = "%s" and (country like "%s" or region like "%s" or city like "%s") order by created_at desc', 
			@db.escape_string(@config[:server][:address]), 
			@db.escape_string(channel), 
			@db.escape_string(place), 
			@db.escape_string(place), 
			@db.escape_string(place)
		)		
		results = @db.query query
		people = []
		results.num_rows.times do
			row = results.fetch_hash
			people.push row["user"]
		end		
		return people
	end
	
	def log(channel, user, ip, lat, long, city, region, country, zip)
		server = @config[:server][:address]
		@db.query(sprintf("insert into log (server, channel, user, ip, latitude, longitude, city, region, country, zipcode, created_at) values (\"%s\", \"%s\", \"%s\", \"%s\", \"%s\", \"%s\", \"%s\", \"%s\", \"%s\", \"%s\", NOW())",
			@db.escape_string(server),
			@db.escape_string(channel),
			@db.escape_string(user),
			@db.escape_string(ip),
			@db.escape_string(lat.to_s),
			@db.escape_string(long.to_s),
			@db.escape_string(city.to_s),
			@db.escape_string(region.to_s),
			@db.escape_string(country.to_s),
			@db.escape_string(zip.to_s)
		))
	end
end

bot = GeoBot.new(ARGV[0])
bot.start