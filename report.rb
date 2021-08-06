require 'json'
require 'csv'

csv_data = IO.read('hospitals.csv', encoding: Encoding::ISO_8859_1).encode(Encoding::UTF_8)

result_map = {}
JSON.parse(File.read("results.json"))["success"].each {|row|
  result_map[row['line_no'] || raise] = row
}

k_map = {}
JSON.parse(File.read("k.json"))["success"].each {|row|
  k_map[row['line_no'] || raise] = row
}

out = CSV.open('output.csv', 'w',
               headers: [
                 'Zeile',
                 'Krankenhaus Name',
                 'Ort',
                 'Name',
                 'Email 1',
                 'Email 2',
                 'Domain',
                 'Imprint',
                 'Alt Emails'
               ], write_headers: true, col_sep: ';', force_quotes: true)


CSV.new(csv_data, col_sep: ';').each.with_index do |row, index|
  line_no = index + 1

  hospital_name, ort = *row

  name = (k_map[line_no] || {})["name"] || ""
  domain = (result_map[line_no] || {})["domain"] || ""
  imprint = (result_map[line_no] || {})["imprint_link"] || ""

  emails1 = ((result_map[line_no] || {})["ranked_emails"] || []).map(&:downcase).map(&:strip).uniq
  emails2 = ((k_map[line_no] || {})["emails"] || []).map(&:downcase).map(&:strip).uniq
  emails = (emails1 + emails2).uniq


  alt_email = ""

  email = if emails1.empty?
            emails2.first
          elsif emails2.empty?
            emails1.first
          else
            a = emails1.first
            b = emails2.first
            if a == b
              a
            else
              if emails2.include?(a)
                a
              elsif emails1.include?(b)
                b
              else
                alt_email = b
                a
              end
            end
          end

  email ||= ""

  alt_emails = emails.join(", ")
  alt_emails = "" if alt_emails == email or alt_emails == alt_email

  out << [line_no.to_s, hospital_name, ort, name, email, alt_email, domain, imprint, alt_emails].map(&:strip)
end

out.close
