require 'capacity_plan/commandsuite'
require 'json'
require 'pony'
require 'capacity_plan/monkeypatch'
require 'kibi'

module Jetpants
  module Plugin
    class Capacity
      @@db

      # set the db and connect
      def initialize
        @@db = Jetpants.topology.pool(Jetpants.plugins['capacity_plan']['pool_name']).master
        @@db.connect(user: Jetpants.plugins['capacity_plan']['user'], schema: Jetpants.plugins['capacity_plan']['schema'], pass: Jetpants.plugins['capacity_plan']['pass'])
      end

      ## grab snapshot of data and store it in mysql 
      def snapshot
        storage_sizes = {}
        timestamp = Time.now.to_i

        current_sizes_storage = current_sizes

        all_mounts.each do |key, value|
          storage_sizes[key] = value
          storage_sizes[key]['db_sizes'] = current_sizes_storage[key]
        end

        store_data(storage_sizes, timestamp)
        snapshot_autoinc(timestamp)
      end

      ## generate the capacity plan and if email is true also send it to the email address listed
      def plan(email=false)
        history = get_history
        mount_stats_storage = all_mounts
        now = Time.now.to_i
        output = ''

        ##get segments for 24 hour blocks
        segments = segmentify(history, 60 * 60 * 24)
        total_mysql_dataset, total_growth_per_day = get_total_consumed_stg(mount_stats_storage, segments)

        output += "\n\n________________________________________________________________________________________________________\n"
        output += "Your MySQL data is #{total_mysql_dataset.first.round(2)}#{total_mysql_dataset.last}. It grew by #{total_growth_per_day.first.round(2)}#{total_growth_per_day.last} since yesterday"

        if Jetpants.topology.respond_to? :capacity_plan_notices
          output += "\n\n________________________________________________________________________________________________________\n"
          output += "Notices\n\n"
          output += Jetpants.topology.capacity_plan_notices
        end

        criticals = []
        warnings = []
        ## check to see if any mounts are currently over the usage points
        mount_stats_storage.each do |key, value|
          if value['used'].to_f/value['total'].to_f > Jetpants.plugins['capacity_plan']['critical_mount']
            criticals << key
          elsif value['used'].to_f/value['total'].to_f > Jetpants.plugins['capacity_plan']['warning_mount']
            warnings << key
          end
        end

        if criticals.count > 0
          output += "\n\n________________________________________________________________________________________________________\n"
          output += "Critical Mounts\n\n"
          criticals.each do |mount|
            output += mount + "\n"
          end
        end

        if warnings.count > 0
          output += "\n\n________________________________________________________________________________________________________\n"
          output += "Warning Mounts\n\n"
          warnings.each do |mount|
            output += mount + "\n"
          end
        end

        output += "\n\n________________________________________________________________________________________________________\n"
        output += "Usage and Time Left\n"
        output += " --------- The 'GB per day' and 'Days left' fields are using a growth rate that is calculated by taking \n --------- an exponentially decaying avg\n\n"

        ##get segments for 24 hour blocks
        segments = segmentify(history, 60 * 60 * 24)

        output += "%30s %20s %10s %10s %16s\n" % ["pool name","Current Data Size","GB per day","Days left","(until critical)"]
        output += "%30s %20s %10s %10s\n" % ["---------","-----------------","----------","---------"]

        mount_stats_storage.each do |name, temp|
          growth_rate = false
          segments[name].each do |range, value|
            growth_rate = calc_avg(growth_rate || value, value)
          end
          critical = mount_stats_storage[name]['total'].to_f * Jetpants.plugins['capacity_plan']['critical_mount']
          if (per_day(bytes_to_gb(growth_rate))) <= 0 || ((critical - mount_stats_storage[name]['used'].to_f)/ per_day(growth_rate)) > 999
            output += "%30s %20.2f %10.2f %10s\n" % [name, bytes_to_gb(mount_stats_storage[name]['used'].to_f), (per_day(bytes_to_gb(growth_rate+0))), 'N/A'] 
          else
            output += "%30s %20.2f %10.2f %10.2f\n" % [name, bytes_to_gb(mount_stats_storage[name]['used'].to_f), (per_day(bytes_to_gb(growth_rate+0))),((critical - mount_stats_storage[name]['used'].to_f)/ per_day(growth_rate))] 
          end
        end

        output += "\n\n________________________________________________________________________________________________________\nDay Over Day\n\n"

        output += "%30s %10s %10s %10s %10s %11s\n" % ["pool name", "today", "1 day ago", "2 days ago", "7 days ago", "14 days ago"]
        output += "%30s %10s %10s %10s %10s %11s\n" % ["---------", "-----", "---------", "----------", "----------", "-----------"]

        mount_stats_storage.each do |name, temp|
          out_array = []
          segments[name].each do |range, value|
            out_array << per_day(bytes_to_gb(value))+0
          end
          output += "%30s %10s %10s %10s %10s %11s\n" % [name, (out_array.reverse[0] ? "%.2f" % out_array.reverse[0] : 'N/A'), (out_array.reverse[1] ? "%.2f" % out_array.reverse[1] : 'N/A'), (out_array.reverse[2] ? "%.2f" % out_array.reverse[2] : 'N/A'), (out_array.reverse[7] ? "%.2f" % out_array.reverse[7] : 'N/A'), (out_array.reverse[14] ? "%.2f" % out_array.reverse[14] : 'N/A')]
        end

        date = Time.now.strftime("%Y-%m-%d")
        autoinc_history = get_autoinc_history(date)
        output += "\n________________________________________________________________________________________________________\nAuto-Increment Checker\n\n"
        output += "Top 5 tables with Auto-Increment filling up are: \n"
        output += "%30s %20s %20s %20s %10s %15s\n" % ["Pool name", "Table name", "Column name", "Column type", "Fill ratio", "Current Max val"]
        autoinc_history.each do |hash_key, value|
          value.each do |table, data|
            output += "%30s %20s %20s %20s %10s %15s\n" % [data["pool"], table, data["column_name"], data["column_type"], data["ratio"], data["max_val"]]
          end
        end

        output += outliers

        collins_results = get_hardware_stats

        output += collins_results

        puts output

        html = '<html><head><meta http-equiv="content-type" content="text/html; charset=UTF-8"></head><body><pre style="font-size=20px;">' + output + '</pre></body></html>'

        if email
          Pony.mail(:to => email, :from => 'jetpants', :subject => 'Jetpants Capacity Plan - '+Time.now.strftime("%m/%d/%Y %H:%M:%S"), :html_body => html, :headers => {'X-category' => 'cronjobr'})
        end
      end

      def bytes_to_gb(size)
        size.to_f / 1024.0 / 1049000.0
      end

      def bytes_to_mb(size)
        size.to_f / 1024.0 / 1024.0
      end

      def per_day(size)
        size * 60 * 60 * 24
      end

      def per_week(size)
        size * 60 * 60 * 24 * 7
      end

      def per_month(size)
        size * 60 * 60 * 24 * 30
      end

      #use an exponentially decaying avg unless there is a count then use a cumulative moving avg
      def calc_avg(avg, new_value, count=false)
        unless count
          (new_value * 0.5) + (avg * (1.0 - 0.5))
        else
          avg + ((new_value - avg) / count)
        end
      end

      ## grab the current sizes from actual data set size including logs (in bytes)
      def current_sizes
        pool_sizes = {}
        Jetpants.pools.each do |p|
          pool_sizes[p.name] = p.data_set_size
        end
        pool_sizes

      end

      ## get all mount's data in kilobytes
      def all_mounts
        all_mount_stats = {}
        Jetpants.pools.each do |p|
          mount_stats = p.mount_stats

          # check if any of the slaves has less total capacity than the master
          p.slaves.each do |s|
            slave_mount_stats = s.mount_stats
            mount_stats = slave_mount_stats if slave_mount_stats['total'] < mount_stats['total']
          end

          all_mount_stats[p.name] ||= mount_stats
        end
        all_mount_stats
      end

      ## get the total MySQL dataset size across whole site
      def get_total_consumed_stg(per_pool_consumed, segments)
        total_consumed = 0
        total_growth = 0
        growth_rate = false
        per_pool_consumed.each do |pool, storage|
          total_consumed += storage["used"]
          segments[pool].each do |range, value|
            growth_rate = calc_avg(growth_rate || value, value)
          end
          total_growth += per_day(growth_rate)
        end

        return Kibi.humanize(total_consumed), Kibi.humanize(total_growth)
      end

      ## loop through data and enter it in mysql
      def store_data(mount_data,timestamp)
        mount_data.each do |key, value|
          @@db.query('INSERT INTO storage (`timestamp`, `pool`, `total`, `used`, `available`, `db_sizes`) VALUES ( ? , ? , ? , ? , ? , ? )', timestamp.to_s, key, value['total'].to_s, value['used'].to_s, value['available'].to_s, value['db_sizes'].to_s)
        end
      end

      ## get history from mysql of all data right now
      def get_history
        history = {}
        @@db.query_return_array('select timestamp, pool, total, used, available, db_sizes from storage order by id').each do |row|
          history[row[:pool]] ||= {}
          history[row[:pool]][row[:timestamp]] ||= {}
          history[row[:pool]][row[:timestamp]]['total'] = row[:total]
          history[row[:pool]][row[:timestamp]]['used'] = row[:used]
          history[row[:pool]][row[:timestamp]]['available'] = row[:available]
          history[row[:pool]][row[:timestamp]]['db_sizes'] = row[:db_sizes]
        end
        history
      end

      ## segment out groups to a given time period
      def segmentify(hash, timeperiod)
        new_hash = {}
        hash.each do |name, temp|
          before_timestamp = false
          keeper = []
          last_timestamp = nil
          last_value = nil
          hash[name].sort.each do |timestamp, value|
            new_hash[name] ||= {}
            last_timestamp = timestamp
            last_value = value
            unless before_timestamp && timestamp > (timeperiod - 60 ) + before_timestamp
              unless before_timestamp
                before_timestamp = timestamp
              end
              keeper << value
            else
              new_hash[name][before_timestamp.to_s+"-"+timestamp.to_s] = (keeper[0]['used'].to_f - value['used'].to_f )/(before_timestamp.to_f - timestamp.to_f)
              before_timestamp = timestamp
              keeper = []
              keeper << value
            end
          end
          if keeper.length > 1
              new_hash[name][before_timestamp.to_s+"-"+last_timestamp.to_s] = (keeper[0]['used'].to_f - last_value['used'].to_f )/(before_timestamp.to_f - last_timestamp.to_f)
          end
        end
        
        new_hash
      end

      # get a hash of machines to display at then end of the email
      # you need to have a method in Jetpants.topology.machine_status_counts to get
      # your machine types and states
      def get_hardware_stats
        
        #see if function exists
        return '' unless Jetpants.topology.respond_to? :machine_status_counts

        data = Jetpants.topology.machine_status_counts

        output = ''
        output += "\n________________________________________________________________________________________________________\n"
        output += "Hardware status\n\n"

        headers = ['status'].concat(data.first[1].keys).concat(['total'])
        output += (headers.map { |i| "%20s"}.join(" ")+"\n") % headers
        output += (headers.map { |i| "%20s"}.join(" ")+"\n") % headers.map { |i| '------------------'}

        data.each do |key, status|
          unless key == 'unallocated'
            total = 0
            status.each do |nodeclass, value|
              total += value.to_i
            end
            output += (headers.map { |i| "%20s"}.join(" ")+"\n") % [key].concat(status.values).concat([total])
          end
        end

        output += "\nTotal Unallocated nodes - " + data['unallocated'] + "\n\n"

        output
      end

      # figure out the outliers for the last 3 days
      def outliers
        output = ''

        output += "\n________________________________________________________________________________________________________\n"
        output += "New Outliers\n"
        output += "--Compare the last 3 days in 2 hour blocks to the same 2 hour block 7, 14, 21, 28 days ago\n\n"

        output += "%30s %25s %25s %10s %11s\n" % ['Pool Name', 'Start Time', 'End Time', 'Usage', 'Prev Weeks']
        output += "%30s %25s %25s %10s %11s\n" % ['---------', '----------', '--------', '-----', '----------']

        block_sizes = 60 * 60 * 2 + 120
        days_from = [7,14,21,28]
        Jetpants.pools.each do |p|
          start_time = Time.now.to_i - 3 * 24 * 60 * 60
          counter = 0
          counter_time = 0
          output_buffer = ''
          last_per = nil

          name = p.name
          while start_time + (60 * 62) < Time.now.to_i
            temp_array = []
            from_blocks = {}
            from_per = {}

            now_block = get_history_block(name, start_time, start_time + block_sizes)
            unless now_block.count == 0                
              now_per = (now_block.first[1]['used'].to_f - now_block.values.last['used'].to_f)/(now_block.first[0].to_f - now_block.keys.last.to_f)


              days_from.each do |days|
                temp = get_history_block(name, start_time - (days * 24 * 60 * 60), start_time - (days * 24 * 60 * 60) + block_sizes)
                if temp.count >= 2
                  from_blocks[days] = temp
                  from_per[days] = (from_blocks[days].first[1]['used'].to_f - from_blocks[days].values.last['used'].to_f)/(from_blocks[days].first[0].to_f - from_blocks[days].keys.last.to_f)
                end
              end

              # remove outliers from compare array because we only care about current outliers not old outliers
              from_per.each do |day, value|
                if(value > from_per.values.mean * 5.0 || value < from_per.values.mean * -5.0)
                  from_per.delete(day)
                end
              end

              if from_per.count > 0
                if((now_per > (from_per.values.mean * 2.2) && from_per.values.mean != 0) || (from_per.values.mean == 0 && now_per > 1048576))
                  if counter == 0
                    counter_time = start_time
                  end
                  counter += 1
                  if counter > 3
                    output_buffer = "%30s %25s %25s %10.2f %11.2f\n" % [name, Time.at(counter_time.to_i).strftime("%m/%d/%Y %H:%M:%S"), Time.at(start_time + block_sizes).strftime("%m/%d/%Y %H:%M:%S"), per_day(bytes_to_gb(now_per)), per_day(bytes_to_gb(from_per.values.mean))]
                  end
                else
                  counter = 0
                  unless output_buffer == ''
                    output += output_buffer
                    output_buffer = ''
                  end
                end

                if((now_per > (from_per.values.mean * 5.0) && from_per.values.mean != 0) || (from_per.values.mean == 0 && now_per > 1048576))
                  output += "%30s %25s %25s %10.2f %11.2f\n" % [name, Time.at(start_time).strftime("%m/%d/%Y %H:%M:%S"), Time.at(start_time + block_sizes).strftime("%m/%d/%Y %H:%M:%S"), per_day(bytes_to_gb(now_per)), per_day(bytes_to_gb(from_per.values.mean))]
                end
              end # end if hash has values

            end

            start_time += block_sizes - 120
          end # end while loop for last 3 days
          output_buffer = ''
          counter = 0
          counter_time = 0
        end 

        output

      end

      ## get history from mysql of all data right now
      def get_history_block(pool,time_start,time_stop)
        history = {}
        @@db.query_return_array('select timestamp, pool, total, used, available, db_sizes from storage where pool = ? and timestamp >= ? and timestamp <= ? order by id', pool, time_start, time_stop).each do |row|
          history[row[:timestamp]] ||= {}
          history[row[:timestamp]]['total'] = row[:total]
          history[row[:timestamp]]['used'] = row[:used]
          history[row[:timestamp]]['available'] = row[:available]
          history[row[:timestamp]]['db_sizes'] = row[:db_sizes]
        end
        history
      end

      def max_value(type)
        case type.downcase
          when "tinyint" then 2**8
          when "smallint" then 2**16
          when "mediumint" then 2**24
          when "int" then 2**32
          when "bigint" then 2**64
        end
      end

      ## get the auto_inc ratios for all pools
      def snapshot_autoinc(timestamp)
        date = Time.now.strftime("%Y-%m-%d")
        if Jetpants.plugins['capacity_plan']['autoinc_ignore_list'].nil?
          pools_list = Jetpants.topology.pools
        else
          ignore_list = Jetpants.plugins['capacity_plan']['autoinc_ignore_list']
          ignore_list.map! { |p| Jetpants.topology.pool(p) }
          pools_list = Jetpants.topology.pools.reject { |p| ignore_list.include? p }
        end
        query = %Q|
          SELECT * 
          FROM INFORMATION_SCHEMA.COLUMNS
          WHERE TABLE_SCHEMA NOT IN 
            ('mysql', 'information_schema', 'performance_schema', 'test') AND 
            LOCATE('auto_increment', EXTRA) > 0
        |
        pools_list.each do |p|
          slave = p.standby_slaves.first
          if !slave.nil?  
            slave.query_return_array(query).each do |row|
              table_name = row[:TABLE_NAME]
              schema_name = row[:TABLE_SCHEMA]
              column_name = row[:COLUMN_NAME]
              column_type = row[:COLUMN_TYPE]
              data_type = row[:DATA_TYPE]
              data_type_max_value = max_value(data_type)
              unless column_type.split.last == "unsigned"
                data_type_max_value = (data_type_max_value / 2) - 1
              end
              sql = "SELECT MAX(#{column_name}) as max_value FROM #{schema_name}.#{table_name}"
              max_val = ''
              slave.query_return_array(sql).each do |row|
                max_val = row[:max_value]
              end
              @@db.query('INSERT INTO auto_inc_checker (`timestamp`, `pool`, `table_name`, `column_name`, `column_type`, `max_val`, `data_type_max`) values (?, ?, ?, ?, ?, ?, ?)', timestamp, slave.pool.to_s, table_name, column_name, data_type,  max_val, data_type_max_value)
            end
          end
        end
      end

      def get_autoinc_history(date)
        auto_inc_history = {}
        query = %Q|
          select 
            from_unixtime(timestamp, '%Y-%m-%d'), pool, table_name,
            column_name, column_type, max_val, data_type_max,
            round((max_val / data_type_max), 2) as ratio 
          from auto_inc_checker 
          where from_unixtime(timestamp, '%Y-%m-%d') = '#{date}' 
          group by pool, table_name 
          order by ratio desc 
          limit 5
        |

        @@db.query_return_array(query).each do |row|
          hash_key = row[:pool] + '.' + row[:table_name]
          auto_inc_history[hash_key] ||= {}
          auto_inc_history[hash_key][row[:table_name]] ||= {}
          auto_inc_history[hash_key][row[:table_name]]['pool'] = row[:pool]
          auto_inc_history[hash_key][row[:table_name]]['column_name'] = row[:column_name]
          auto_inc_history[hash_key][row[:table_name]]['column_type'] = row[:column_type]
          auto_inc_history[hash_key][row[:table_name]]['max_val'] = row[:max_val]
          auto_inc_history[hash_key][row[:table_name]]['data_type_max'] = row[:data_type_max]
          auto_inc_history[hash_key][row[:table_name]]['ratio'] = row[:ratio].to_f
        end
        return auto_inc_history
      end
    end
  end
end
