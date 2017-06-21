#-- copyright
# ReportingEngine
#
# Copyright (C) 2010 - 2014 the OpenProject Foundation (OPF)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# version 3.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#++

module Report::QueryUtils
  Infinity = 1.0 / 0
  include Engine

  alias singleton_class metaclass unless respond_to? :singleton_class

  delegate :quoted_false, :quoted_true, to: 'engine.reporting_connection'
  attr_writer :engine

  module PropagationHook
    include Report::QueryUtils

    def append_features(base)
      ancestors[1..-1].reverse_each { |m| base.send(:include, m) }
      base.extend PropagationHook
      base.extend self
      super
    end

    def propagate!(to = engine)
      to.constants(false).each do |name|
        const = to.const_get name
        next unless Module === const
        append_features const unless const <= self or not const < Report::QueryUtils
        propagate! const
      end
    end
  end

  extend PropagationHook

  ##
  # Graceful string quoting.
  #
  # @param [Object] str String to quote
  # @return [Object] Quoted version
  def quote_string(str)
    return str unless str.respond_to? :to_str
    engine.reporting_connection.quote_string(str)
  end

  def current_language
    ::I18n.locale
  end

  ##
  # Creates a SQL fragment representing a collection/array.
  #
  # @see quote_string
  # @param [#flatten] *values Ruby collection
  # @return [String] SQL collection
  def collection(*values)
    return '' if values.empty?

    v = if values.is_a?(Array)
          values.flatten.each_with_object([]) do |str, l|
            l << split_with_safe_return(str)
          end
        else
          split_with_safe_return(str)
        end

    "(#{v.flatten.map { |x| "'#{quote_string(x)}'" }.join(', ')})"
  end

  def split_with_safe_return(str)
    # From ruby doc:
    # When the input str is empty an empty Array is returned as the string is
    # considered to have no fields to split.
    str.to_s.empty? ? '' : str.to_s.split(',')
  end

  ##
  # Graceful, internationalized quoted string.
  #
  # @see quote_string
  # @param [Object] str String to quote/translate
  # @return [Object] Quoted, translated version
  def quoted_label(ident)
    "'#{quote_string ::I18n.t(ident)}'"
  end

  def quoted_date(date)
    engine.reporting_connection.quoted_date date.to_dateish
  end

  ##
  # SQL date quoting.
  # @param [Date,Time] date Date to quote.
  # @return [String] Quoted date.
  def quote_date(date)
    "'#{quoted_date date}'"
  end

  ##
  # Generate a table name for any object.
  #
  # @example Table names
  #   table_name_for Issue    # => 'issues'
  #   table_name_for :issue   # => 'issues'
  #   table_name_for "issue"  # => 'issues'
  #   table_name_for "issues" # => 'issues
  #
  # @param [#table_name, #to_s] object Object you need the table name for.
  # @return [String] The table name.
  def table_name_for(object)
    return object.table_name if object.respond_to? :table_name
    object.to_s.tableize
  end

  ##
  # Generate a field name
  #
  # @example Field names
  #   field_name_for nil                            # => 'NULL'
  #   field_name_for 'foo'                          # => 'foo'
  #   field_name_for [Issue, 'project_id']          # => 'issues.project_id'
  #   field_name_for [:issue, 'project_id'], :entry # => 'issues.project_id'
  #   field_name_for 'project_id', :entry           # => 'entries.project_id'
  #
  # @param [Array, Object] arg Object to generate field name for.
  # @param [Object, optional] default_table Table name to use if no table name is given.
  # @return [String] Field name.
  def field_name_for(arg, default_table = nil)
    return 'NULL' unless arg
    return field_name_for(arg.keys.first, default_table) if arg.is_a? Hash
    return arg if arg.is_a? String and arg =~ /\.| |\(.*\)/
    return table_name_for(arg.first || default_table) + '.' << arg.last.to_s if arg.is_a? Array and arg.size == 2
    return arg.to_s unless default_table
    field_name_for [default_table, arg]
  end

  ##
  # Sanitizes sql condition
  #
  # @see ActiveRecord::Base#sanitize_sql_for_conditions
  # @param [Object] statement Not sanitized statement.
  # @return [String] Sanitized statement.
  def sanitize_sql_for_conditions(statement)
    engine.send :sanitize_sql_for_conditions, statement
  end

  ##
  # FIXME: This is redmine
  # Generates string representation for a currency.
  #
  # @see CostRate.clean_currency
  # @param [BigDecimal] value
  # @return [String]
  def clean_currency(value)
    CostRate.clean_currency(value).to_f.to_s
  end

  ##
  # Generates a SQL case statement.
  #
  # @example
  #   switch "#{table}.overridden_costs IS NULL" => [model, :costs], :else => [model, :overridden_costs]
  #
  # @param [Hash] options Condition => Result.
  # @return [String] Case statement.
  def switch(options)
    desc = "#{__method__} #{options.inspect[1..-2]}".gsub(/(Cost|Time)Entry\([^\)]*\)/, '\1Entry')
    options = options.with_indifferent_access
    else_part = options.delete :else
    "-- #{desc}\n\t" \
    "CASE #{options.map { |k, v|
      "\n\t\tWHEN #{field_name_for k}\n\t\t" \
    "THEN #{field_name_for v}"
    }.join(', ')}\n\t\tELSE #{field_name_for else_part}\n\tEND"
  end

  def iso_year_week(field, default_table = nil)
    field = field_name_for(field, default_table)
    "-- code specific for #{adapter_name}\n\t" << super(field)
  end

  ##
  # Converts value with a given behavior, but treats nil differently.
  # Params
  #  - value: the value to convert
  #  - weight_of_nil (optional): How a nil should be treated.
  #    :infinit - makes a nil weight really heavy, which will make it stay
  #               at the very end when sorting
  #    :negative_infinit - opposite of :infinit, let's the nil stay at the very beginning
  #    any other object - nil's will be replaced by thyt object
  #  - block (optional) - defines how to convert values which are not nil
  #               if no block is given, values stay untouched
  def convert_unless_nil(value, weight_of_nil = :infinit)
    if value.nil?
      if weight_of_nil == :infinit
        1.0 / 0 # Infinity, which is greater than any string or number
      elsif weight_of_nil == :negative_infinit
        -1.0 / 0 # negative Infinity, which is smaller than any string or number
      else
        weight_of_nil
      end
    else
      if block_given?
        yield value
      else
        value
      end
    end
  end

  def map_field(key, value)
    case key.to_s
    when 'singleton_value', /_id$/ then convert_unless_nil(value) { |v| v.to_i }
    when 'work_package_id', 'tweek', 'tmonth', 'tweek' then value.to_i
    else convert_unless_nil(value) { |v| v.to_s }
    end
  end

  def adapter_name
    engine.reporting_connection.adapter_name.downcase.to_sym
  end

  def cache
    Report::QueryUtils.cache
  end

  def compare(first, second)
    first  = Array(first).flatten
    second = Array(second).flatten
    first.zip second do |a, b|
      return (a <=> b) || (a == Infinity ? 1 : -1) if a != b
    end
    second.size > first.size ? -1 : 0
  end

  def mysql?
    [:mysql, :mysql2].include? adapter_name.to_s.downcase.to_sym
  end

  def sqlite?
    adapter_name == :sqlite
  end

  def postgresql?
    adapter_name == :postgresql
  end

  module SQL
    def typed(_type, value, escape = true)
      escape ? "'#{quote_string value}'" : value
    end
  end

  module MySql
    include SQL
    def iso_year_week(field)
      "yearweek(#{field}, 1)"
    end
  end

  module Sqlite
    include SQL
    def iso_year_week(field)
      # enjoy
      <<-EOS
        case
        when strftime('%W', strftime('%Y-01-04', #{field})) = '00' then
          -- 01/01 is in week 1 of the current year => %W == week - 1
          case
          when strftime('%W', #{field}) = '52' and strftime('%W', (strftime('%Y', #{field}) + 1) || '-01-04') = '00' then
            -- we are at the end of the year, and it's the first week of the next year
            (strftime('%Y', #{field}) + 1) || '01'
          when strftime('%W', #{field}) < '08' then
            -- we are in week 1 to 9
            strftime('%Y0', #{field}) || (strftime('%W', #{field}) + 1)
          else
            -- we are in week 10 or later
            strftime('%Y', #{field}) || (strftime('%W', #{field}) + 1)
          end
        else
            -- 01/01 is in week 53 of the last year
            case
            when strftime('%W', #{field}) = '52' and strftime('%W', (strftime('%Y', #{field}) + 1) || '-01-01') = '00' then
              -- we are at the end of the year, and it's the first week of the next year
              (strftime('%Y', #{field}) + 1) || '01'
            when strftime('%W', #{field}) = '00' then
              -- we are in the week belonging to last year
              (strftime('%Y', #{field}) - 1) || '53'
            else
              -- everything is fine
              strftime('%Y%W', #{field})
            end
        end
      EOS
    end
  end

  module Postres
    include SQL
    def typed(type, value, escape = true)
      "#{super}::#{type}"
    end

    def iso_year_week(field)
      "(EXTRACT(isoyear from #{field})*100 + \n\t\t" \
      "EXTRACT(week from #{field} - \n\t\t" \
      "(EXTRACT(dow FROM #{field})::int+6)%7))"
    end
  end

  include MySql if mysql?
  include Sqlite if sqlite?
  include Postres if postgresql?

  def self.cache
    @cache ||= Hash.new { |h, k| h[k] = {} }
  end

  def self.included(klass)
    super
    klass.extend self
  end
end
