require_relative '../test_helper'
require 'find'

class SchemaTest < ActiveSupport::TestCase
  test 'schemas' do
    Find.find(CONFIG['schema_location']).each do |f|
      io = nil
      case f
      when /\.rng$/
        testfile = f.gsub(/\.rng$/, '.xml')
        if File.exist?(testfile)
          io = IO.popen("xmllint --noout --relaxng #{f} #{testfile} 2>&1 > /dev/null", 'r')
        end
      when /xsd/
        testfile = f.gsub(/\.xsd$/, '.xml')
        if File.exist?(testfile)
          io = IO.popen("xmllint --noout --schema #{f} #{testfile} 2>&1 > /dev/null", 'r')
        end
      end
      next unless io

      testresult = io.read
      io.close
      assert $CHILD_STATUS == 0, "#{testfile} does not validate against #{f} -> #{testresult}"
    end
  end
end
