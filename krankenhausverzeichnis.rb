require 'cgi'
require 'pp'
require 'uri'
require 'json'
require 'nokogiri'
require 'open-uri'
require 'net/http'

class String
  def strip_prefix(prefix)
    if self.start_with?(prefix)
      self[prefix.size..-1]
    else
      self
    end
  end
end

class Crawler
  def initialize
    reconnect
  end

  def reconnect
    @https.close if @https
    @https = Net::HTTP.new('www.deutsches-krankenhaus-verzeichnis.de', 443)
    @https.use_ssl = true
  end

  def search_detail(searchterm)
    request = Net::HTTP::Post.new('/app/suche/ergebnis')
    request.set_form_data({"search[whereSearchString]" => searchterm})

    response = @https.request(request)
    doc = Nokogiri::HTML(response.body)
    return doc.css('#dkv_result_table_row > tr > td > address > strong > a').attribute("href").value
  rescue
    nil
  end

  def fetch_detail(path)
    request = Net::HTTP::Get.new(path)
    response = @https.request(request)
    doc = Nokogiri::HTML(response.body)
    emails = []

    doc.css("#dkv_content section.head .row a").each do |elm|
      href = elm.attribute('href')
      if href and href.value =~ /mailto:(.*)$/i
        emails << $1.chomp
      end
    end

    if name = doc.css("#dkv_content h1")
      name = name.text.chomp
    end

    {emails: emails, name: name}
  end
end

if __FILE__ == $0
  c = Crawler.new

  success = []
  failed = []

  lines = IO.readlines(ARGV[0] || raise, chomp: true, encoding: Encoding::ISO_8859_1).map.with_index {|line, line_no|
   [line_no+1, line.encode(Encoding::UTF_8)]
  }

  for line_no, line in lines
    st = line.squeeze(" ").split(/[ ;-]/).map {|t| t.chomp}.reject{|t| t.empty?}.uniq.join(" ")
    puts("%04d | %s" % [line_no, st])

    begin
      detail_link = c.search_detail(st)
      if detail_link
        info = c.fetch_detail(detail_link)
        success << {line_no: line_no, line: line, st: st, detail_link: detail_link, emails: info[:emails], name: info[:name]}
      else
        raise "No detail link found"
      end
    rescue => ex
      STDERR.puts "!!!! | ERROR: #{ex}"
      failed << {line_no: line_no, line: line, message: ex.message}
    end
  end

  File.write("k.json", {success: success, failed: failed}.to_json) 
end
