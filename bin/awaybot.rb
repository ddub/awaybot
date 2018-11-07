#!/usr/bin/ruby

require 'rubygems'
require 'bundler/setup'
require 'chronic_duration'
require 'slack-notifier'
require 'open-uri'
require 'icalendar'
require 'yaml'
require 'date'
require 'pp'

puts 'Running...'
cfg = YAML.load_file('awaybot.yaml')
type = ARGV[0]
unless cfg.key? "#{type}_announce"
  puts "#{type} is not a known type of announcement."
  Kernel.exit 1
end

today = Date.today
puts "Running for #{today}"

ics_raw = URI.parse(ENV['FEED_URL']).read
ics = Icalendar.parse(ics_raw).first
msg = ''

if ENV['DEBUG']
  puts "Team:"
  puts ENV['NAMES'].split(';')
end

people = {}
ics.events.each do |event|
  puts "#{event.summary} (#{event.dtstart} - #{event.dtend})" if ENV['DEBUG']
  # Summary in the form of: "FirstName LastName (Time off - 0.5 days)"
  name = (/[^\(]+/.match event.summary)[0].strip
  unless ENV['NAMES'].split(';').include? name
    puts "#{name} not in team"
    next
  end

  people[name] = Array.new unless people.key?(name)

  away_start = event.dtstart - 0
  away_end = event.dtend - 1
  return_day = away_end + 1
  # people don't return on the weekend, bump the return day to monday
  return_day += 1 while return_day.saturday? || return_day.sunday?
  away_range = away_start..away_end
  away_duration = (away_end - away_start).to_i + 1
  # Can't tell a partial day from the dates, but it is in the summary
  partial_day = (/([0-9\.]+) day/.match event.summary)[1].to_i < 1
  # subtract any weekends from the duration
  away_range.each do |date|
    away_duration -= 1 if date.saturday? || date.sunday?
  end
  look_range =
    today..(today + cfg["#{type}_announce"]['look_forward_days'])
  next if (away_range.to_a & look_range.to_a).empty?

  people[name].push({
    away_start: away_start,
    away_end: away_end,
    return_day: return_day,
    away_range: away_range,
    away_duration: away_duration,
    partial_day: partial_day,
  })
end

people.each do |full_name, all_time_off|
  aggregated_time_off = Array.new

  if all_time_off.length > 1
    first_time_block = all_time_off.shift
    all_time_off.each_with_index do |time_off, index|
      if time_off[:away_start] <= first_time_block[:return_day]
        aggregated_time_off.push({
          away_start: first_time_block[:away_start],
          away_end: time_off[:away_end],
          return_day: time_off[:return_day],
          away_range: first_time_block[:away_start]..time_off[:away_end],
          away_duration: (time_off[:away_end] - first_time_block[:away_start]).to_i + 1,
          partial_day: time_off[:partial_day],
        })
        first_time_block = all_time_off[index + 1]
      end
    end
  else
    aggregated_time_off = all_time_off
  end

  puts aggregated_time_off

  aggregated_time_off.each do |time_off|
    if time_off[:away_start] > today
      if time_off[:away_duration] == 1 and time_off[:partial_day]
        msg += "#{full_name} is off for part of the day on" \
          " #{time_off[:away_start].strftime('%A, %B %-d')}.\n"
      elsif time_off[:away_duration] == 1
        msg += "#{full_name} is off for the day on" \
          " #{time_off[:away_start].strftime('%A, %B %-d')}.\n"
      else
        if today.strftime('%A') == time_off[:away_start].strftime('%A')
          nxt = 'next '
        else
          nxt = ''
        end
        msg += "#{full_name} is off for #{time_off[:away_duration]} days starting" \
          " #{nxt}#{time_off[:away_start].strftime('%A, %B %-d')} until" \
          " #{time_off[:return_day].strftime('%A, %B %-d')}.\n"
      end
    else
      if time_off[:away_end] - today > 0
        text_return = ChronicDuration.output(
          (time_off[:return_day] - today) * 60 * 60 * 24, weeks: true, format: :long, units: 2
        )
        msg += "#{full_name} is off today, returning in #{text_return} on #{time_off[:return_day].strftime('%A, %B %-d')}.\n"
      elsif time_off[:partial_day]
        msg += "#{full_name} is off part of today.\n"
      else
        msg += "#{full_name} is off today.\n"
      end
    end
  end
end

if (msg == '' and ENV['SHOW_EMPTY'].downcase == 'true')
  msg = "No vacations planned. :briefcase:"
elsif msg != ''
  msg = ":city_sunrise: Good morning! Here's who's off for the next" \
    " #{cfg["#{type}_announce"]['look_forward_days']} days.\n#{msg}"
end

if msg != '' && !today.saturday? && !today.sunday?
  puts msg
  slack = Slack::Notifier.new ENV['SLACK_HOOK_URL']
  slack.ping msg
end
