#
# Howto decrypt "pseudo-encrypted" mailto: links taken from [1] and [2].
#
# [1]: http://www.communitygrove.com/guides/avoiding-obfuscated-email-addresses
# [2]: https://stackoverflow.com/questions/65725064/typo3-encrypted-mailto-link-javascriptlinkto-uncryptmailto-not-working-with-s
#

require 'cgi'
require 'selenium-webdriver'
require 'pp'
require 'uri'
require 'json'
require 'nokogiri'
require 'open-uri'

CHAR_RANGES = [
  0x2B .. 0x3A, # 0-9 . , - + / :
  0x40 .. 0x5A, # A-Z @
  0x61 .. 0x7A, # a-z
]

def rotate_codepoint(cp, range, offset)
    cp += offset
    if offset > 0 and cp > range.last
      cp += range.first - range.last - 1
    elsif offset < 0 and cp < range.first
      cp += range.last - range.first + 1
    end 
    cp
end

def decrypt_codepoint(cp, offset)
  CHAR_RANGES.each do |range|
    if range.include?(cp)
      return rotate_codepoint(cp, range, offset)
    end
  end
  cp
end

def decrypt_string(enc, offset)
  enc.each_codepoint.map {|cp|
    decrypt_codepoint(cp, offset)
  }.pack("U*")
end

class String
  def strip_prefix(prefix)
    if self.start_with?(prefix)
      self[prefix.size..-1]
    else
      self
    end
  end
end


def decode_mailto(mailto, domain='.de')
  mailto = decode_mailto_exact(mailto, domain)
  return mailto if mailto.include?('@')

  for suffix in %w(de eu org com net info fr uk us)
    mailto = decode_mailto_exact(mailto, suffix)
    return mailto if mailto and mailto.include?('@')
  end

  # (-14..14).upto {|offset| }

  raise "Cannot decode mail: #{mailto}"
end

def decode_mailto_exact(mailto, domain='.de')
    p mailto
    # Unescape javascript string
    mailto = mailto.gsub(/\\./) {|m| m[1]}

    # emails end with last character of `domain`
    offset = (domain[-1].ord - mailto[-1].ord)
    p offset
    mailto = decrypt_string(mailto, offset)
    mailto = mailto.strip_prefix("mailto ")
    mailto = mailto.strip_prefix("mailto:")
    mailto.strip

    mailto
end

def wait_until(timeout: 10, &block)
  Selenium::WebDriver::Wait.new(timeout: timeout).until(&block)
end

class Fetcher
  def initialize(rate_limit_per_host_per_second: 1)
  end

  def fetch(url)
    uri = URI.parse(url)
    uri.open {|f|
      f.read
    }
  rescue => ex
    STDERR.puts "Got exception in Fetcher: #{ex}"
  end
end



class DuckduckGo
  def initialize(driver)
    @driver = driver
  end

  def submit_search(searchterm)
    STDERR.puts "Loading duckduckgo"

    @driver.get "https://duckduckgo.com/"

    wait_until {
      @driver.execute_script("return document.readyState;") == 'complete'
    }

    STDERR.puts "duckduckgo loaded"

    elm = wait_until {
      @driver.find_element(id: 'search_form_input_homepage')
    }

    if elm
      elm.send_keys searchterm
      elm.submit
    else
      raise "Input not found"
    end

    STDERR.puts "Searchterm submitted"
  end

  def load_results_directly(searchterm)
    @driver.get "https://duckduckgo.com/?q=#{CGI.escape(searchterm)}"
    STDERR.puts "Searchterm submitted"
  end

  def first_search_result
    wait_until {
      @driver.execute_script("return document.readyState;") == 'complete'
    }

    STDERR.puts "Results page loaded"

    link = wait_until { @driver.find_element(css: ".results .result a") }

    site_link = link['href']

    return site_link
  end

  def self.search(driver, searchterm)
    STDERR.puts "Searchterm <#{searchterm}>"
    engine = new(driver)
    # engine..submit_search(searchterm)
    engine.load_results_directly(searchterm)
    engine.first_search_result
  end
end

class Crawler
  attr_reader :driver, :fetcher

  def initialize(driver:, fetcher:)
    @driver = driver
    @fetcher = fetcher
  end

  def url_from_searchterm(searchterm)
    site_link = DuckduckGo.search(@driver, searchterm)

    STDERR.puts "Site: #{site_link}"

    site_link
  end

  def crawl_site_from_searchterm(searchterm)
    site_link = url_from_searchterm(searchterm)
    crawl_site_using_fetcher(site_link)
  end

  def crawl_site_using_driver(site_link)
    domain = URI.parse(site_link).host
    mail_domain = domain.strip_prefix("www.")

    @driver.get(site_link)

    wait_until {
      @driver.execute_script("return document.readyState;") == 'complete'
    }

    @driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")

    found_emails = []

    @driver.find_element(css: 'body').text.scan(/[0-9A-Za-z.,+\/:-]+@[^.]+\.de/) {|match|
      found_emails << match
    }

    uses_encryption = false

    @driver.find_elements(tag_name: "a").each { |elm|
      href = elm['href']
      case href
      when /^mailto:/i
        href = CGI.unescape(href)
        email = href.strip_prefix("mailto:").strip
        if email.include?("@")
          found_emails << email 
        else
          STDERR.puts "invalid mailto link"
        end
      when /^javascript:linkto/i
        href = CGI.unescape(href)
        if href =~ /javascript:linkTo_UnCryptMailto\s*\(\'([^']*)'/i
          begin
            found_emails << decode_mailto($1, mail_domain)
          rescue => ex
            STDERR.puts ex.message
          end
          uses_encryption = true
        else
          STDERR.puts "Cannot decrypt javascript linkto: #{href}"
        end
      end
    }

    {
      email: found_emails,
      ranked_emails: rank_emails(found_emails, mail_domain).map{|a| a[1]},
      imprint_link: site_link,
      domain: domain,
      mail_domain: mail_domain,
      uses_encryption: uses_encryption
    }
  end


  def crawl_site_using_fetcher(site_link)
    domain = URI.parse(site_link).host
    mail_domain = domain.strip_prefix("www.")

    body = @fetcher.fetch site_link
    doc = Nokogiri::HTML(body)

    found_emails = []

    doc.css('body').first.content.scan(/[0-9A-Za-z.,+\/:-]+@[^.]+\.de/) {|match|
      found_emails << match
    }

    uses_encryption = false

    doc.css('a').each { |elm|
      href = elm['href']
      case href
      when /^mailto:/i
        href = CGI.unescape(href)
        email = href.strip_prefix("mailto:").strip
        if email.include?("@")
          found_emails << email 
        else
          STDERR.puts "invalid mailto link"
        end
      when /^javascript:linkto/i
        href = CGI.unescape(href)
        if href =~ /javascript:linkTo_UnCryptMailto\s*\(\'([^']*)'/i
          found_emails << decode_mailto($1, mail_domain)
          uses_encryption = true
        else
          STDERR.puts "Cannot decrypt javascript linkto: #{href}"
        end
      end
    }

    {
      email: found_emails,
      ranked_emails: rank_emails(found_emails, mail_domain).map{|a| a[1]},
      imprint_link: site_link,
      domain: domain,
      mail_domain: mail_domain,
      uses_encryption: uses_encryption
    }
  end
end

def rank_emails(emails, mail_domain)
  hash = {}

  emails = emails.map{|e| e.downcase.strip}

  emails.each {|email|
    mail_part, domain_part = email.split('@')
    raise "Invalid email: #{email}" if mail_part.nil? or domain_part.nil?
    hash[domain_part] ||= Hash.new(0)
    hash[domain_part][mail_part] += 1
  }

  hash.each_value {|h|
    for score_higher in %w(info kontakt)
      h[score_higher] += 1000 if h.has_key?(score_higher)
    end

    slightly_better_keys = h.each_key.select {|k| k =~ /service/ || k =~ /krankenhaus/}
    for k in slightly_better_keys
      h[k] += 50
    end
  }

  list = []

  if e = hash.delete(mail_domain)
    e.each_pair {|mail_part, score| list << [score, mail_part + '@' + mail_domain]}
  end

  hash.each_pair{|domain_part, e|
    e.each_pair {|mail_part, score| list << [score, mail_part + '@' + domain_part]}
  }

  list.sort_by {|a| -a[0]}.uniq
end

class State
  attr_reader :success, :failed, :remaining

  def initialize(success: [], failed: [], remaining: [])
    raise if success.nil? or failed.nil? or remaining.nil?
    @success = success
    @failed = failed
    @remaining = remaining
  end

  def save!(filename)
    STDERR.puts "Writing state to #{filename}"
    File.write(filename, self.to_json)
  end

  def self.load(filename)
    json = JSON.load(File.read(filename))
    new(success: json['success'], failed: json['failed'], remaining: json['remaining'])
  end

  def to_json
    {success: @success, failed: @failed, remaining: @remaining}.to_json
  end
end

def crawl_all(state, snapshot_every_seconds: nil)
  crawler = Crawler.new(driver: Selenium::WebDriver.for(:chrome), fetcher: Fetcher.new)

  last_snapshot = nil
  snapshot_no = 1
  started_at = Time.now

  loop do
    if snapshot_every_seconds
      if last_snapshot.nil? or (Time.now - last_snapshot) > snapshot_every_seconds
        last_snapshot = Time.now
        state.save!("snapshot_%04d_s%d_%d.json" % [snapshot_no, started_at, last_snapshot.to_i])
        snapshot_no += 1
      end
    end
  
    entry = state.remaining.shift
    break unless entry

    line_no, line = entry
    p line_no, line

    begin

      info = crawler.crawl_site_from_searchterm(line + " Impressum")
      info[:line] = line
      info[:line_no] = line_no
      pp info

      state.success << info
    rescue Exception => ex
      p ex
      driver = nil
      state.failed << {line_no: line_no, line: line, error: ex.message, backtrace: ex.backtrace}
    end
  end
ensure
  crawler.driver.quit
end

if __FILE__ == $0
  state = nil

  case ARGV[0]
  when 'new'
    lines = IO.readlines(ARGV[1] || raise, chomp: true, encoding: Encoding::ISO_8859_1).map.with_index {|line, line_no|
      [line_no+1, line.encode(Encoding::UTF_8)]
    }

    state = State.new(remaining: lines)
  when 'load-snapshot'
    state = State.load(ARGV[1] || raise)
  when 'retry-failed'
    state = State.load(ARGV[1] || raise)
    state.failed.each do |entry|
      state.remaining << [entry['line_no'], entry['line']]
    end
    state.failed.clear
  else
    raise "Usage: #{$0} new <file> | load-snapshot <snapshot> | retry-failed <snapshot>"
  end

  begin
    crawl_all(state, snapshot_every_seconds: 60 * 5)
  ensure
    state.save!("results.json")
  end
end
