#!/usr/bin/env ruby
# encoding: utf-8
# Pobiera imprezy rowerowe ze źródeł i wstawia je do index.html.
# Użycie: ruby aktualizuj.rb
require "json"
require "cgi"
require "date"
require "open3"

DIR  = __dir__
HTML = File.join(DIR, ARGV[0] || "index.html")
UA   = "KalendarzSzutrowISzos/1.0 (prywatny kalendarz imprez; aktualizacja raz w tygodniu)"
WOJ  = %w[dolnośląskie kujawsko-pomorskie lubelskie lubuskie łódzkie małopolskie mazowieckie opolskie
          podkarpackie podlaskie pomorskie śląskie świętokrzyskie warmińsko-mazurskie wielkopolskie zachodniopomorskie]
MIES = %w[stycznia lutego marca kwietnia maja czerwca lipca sierpnia września października listopada grudnia]

def get(url)
  out, st = Open3.capture2("curl", "-sL", "-m", "30", "-A", UA, url)
  raise "Nie udało się pobrać #{url}" unless st.success? && !out.empty?
  out.force_encoding("utf-8").scrub
end

def norm(s)
  s.to_s.downcase.tr("ąćęłńóśźż", "acelnoszz").gsub(/\b20\d\d\b/, "").gsub(/[^a-z0-9]+/, " ").strip
end

def pl_date(s)
  return nil unless s =~ /(\d{1,2}) (\p{L}+) (\d{4})/
  m = MIES.index($2) or return nil
  format("%04d-%02d-%02d", $3.to_i, m + 1, $1.to_i)
end

def km(list)
  list = list.compact.uniq.sort
  list.empty? ? nil : list.map { |d| d % 1 == 0 ? d.to_i : d }.join(" / ") + " km"
end

# --- gravelradar.cc: publiczny plik events.json -------------------------------
def gravelradar
  JSON.parse(get("https://gravelradar.cc/events.json"))["events"].map do |e|
    tags = (e["tags"] || []).map(&:downcase)
    types = []
    types << "gravel" if (tags & %w[gravel grevet]).any?
    types << "road" if (tags & %w[szosa brevet]).any?
    types << "mtb" if tags.include?("mtb")
    types << "gravel" if types.empty?
    loc = e["location"] || {}
    { "name" => e["name"], "types" => types, "start" => e["startDate"], "end" => e["endDate"] || e["startDate"],
      "place" => loc["city"], "region" => loc["voivodeship"].to_s.downcase,
      "dist" => km((e["routes"] || []).map { |r| r["distance_km"] }),
      "tags" => tags - %w[gravel szosa mtb racevisuals],
      "url" => e["website"].to_s.empty? ? nil : e["website"], "src" => ["gravelradar.cc"] }
  end
end

# --- kalendarzrowerowy.pl: strony miesięcy + strona każdej imprezy -------------
def kalendarzrowerowy(from)
  rows = {}
  15.times do |i|
    m = from >> i
    html = get("https://kalendarzrowerowy.pl/kalendarz/?miesiac=#{m.strftime('%Y-%m')}")
    html.scan(%r{<a\s+href="(/wydarzenie/[^"]+)"\s+class="event-row"\s*>(.*?)</a>}m).each do |href, body|
      next if rows[href]
      title = body[%r{event-row__title">(.*?)</h3>}m, 1]
      dates = body[%r{calendar_today</span>\s*(.*?)\s*</span>}m, 1].to_s
      place = body[%r{location_on</span>\s*(.*?)\s*</span>}m, 1]
      cats  = body.scan(/chip-cat-([a-z-]+)"/).flatten
      a, b  = dates.split(" - ")
      rows[href] = { "name" => CGI.unescapeHTML(title.to_s.strip), "start" => pl_date(a), "end" => pl_date(b || a),
                     "place" => CGI.unescapeHTML(place.to_s.strip), "cats" => cats,
                     "dist" => body[%r{event-row__blurb">Wariant: (.*?)</p>}m, 1], "href" => href }
    end
    sleep 1
  end
  today = Date.today.to_s
  rows.values.select { |r| r["start"] && r["end"] >= today }.map do |r|
    page = get("https://kalendarzrowerowy.pl#{r['href']}")
    sleep 1
    ld = page.scan(%r{<script type="application/ld\+json"[^>]*>(.*?)</script>}m).flatten
             .map { |j| JSON.parse(j) rescue nil }.compact.find { |j| j["@type"] == "SportsEvent" } || {}
    addr = ld.dig("location", "address") || {}
    next if addr["addressCountry"] && addr["addressCountry"] != "PL"
    site = page[%r{<a\s+class="btn btn-primary[^"]*"\s+href="(https?://[^"]+)"}m, 1]
    types = { "gravel" => "gravel", "szosa" => "road", "mtb" => "mtb" }.select { |k, _| r["cats"].include?(k) }.values
    types << "gravel" if types.empty?
    { "name" => r["name"].sub(/\s*\(?20\d\d\)?\s*$/, ""), "types" => types, "start" => r["start"], "end" => r["end"],
      "place" => r["place"], "region" => addr["addressRegion"].to_s.downcase, "dist" => r["dist"],
      "tags" => r["cats"].include?("etapowka") ? ["etapówka"] : [],
      "url" => site ? CGI.unescapeHTML(site) : "https://kalendarzrowerowy.pl#{r['href']}", "src" => ["kalendarzrowerowy.pl"] }
  end.compact
end

def same?(a, b)
  return false unless a["start"] == b["start"]
  na, nb = norm(a["name"]), norm(b["name"])
  na.include?(nb) || nb.include?(na) || (na.split & nb.split).size >= 2
end

today = Date.today
first = Date.new(today.year, today.month, 1)
events = []
errors = []
[["gravelradar.cc", -> { gravelradar }], ["kalendarzrowerowy.pl", -> { kalendarzrowerowy(first) }]].each do |name, fn|
  begin
    list = fn.call
    warn "#{name}: #{list.size} imprez"
    list.each do |e|
      if (dup = events.find { |x| same?(x, e) })
        dup["src"] |= e["src"]
        dup["types"] |= e["types"]
        %w[dist region place url].each { |k| dup[k] = e[k] if dup[k].to_s.empty? }
      else
        events << e
      end
    end
  rescue => err
    errors << "#{name}: #{err.message}"
  end
end

events.select! { |e| e["start"] && e["end"] >= today.to_s && WOJ.include?(e["region"]) }
events.sort_by! { |e| [e["start"], e["name"]] }
abort "Żadne źródło nie zwróciło imprez, plik zostaje bez zmian. #{errors.join('; ')}" if events.size < 10

data = { "updated" => today.to_s, "events" => events }
json = JSON.generate(data).gsub("</", "<\\/")
html = File.read(HTML, encoding: "utf-8")
re = %r{(<script type="application/json" id="dane">).*?(</script>)}m
abort "Nie znalazłem bloku danych w #{HTML}" unless html =~ re
File.write(HTML, html.sub(re) { "#{$1}#{json}#{$2}" })
File.write(File.join(DIR, "imprezy.json"), JSON.pretty_generate(data))
warn "Zapisano #{events.size} imprez (#{events.first['start']} – #{events.last['start']})"
warn "Błędy: #{errors.join('; ')}" unless errors.empty?
