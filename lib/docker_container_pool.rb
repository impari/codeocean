require 'concurrent/future'
require 'concurrent/timer_task'
require 'concurrent/utilities'

class DockerContainerPool
  TIME_TILL_RESTART = 900

  @containers = ThreadSafe::Hash[ExecutionEnvironment.all.map { |execution_environment| [execution_environment.id, ThreadSafe::Array.new] }]
  #as containers are not containing containers in use
  @all_containers = ThreadSafe::Hash[ExecutionEnvironment.all.map { |execution_environment| [execution_environment.id, ThreadSafe::Array.new] }]
  def self.clean_up
    @refill_task.try(:shutdown)
    @containers.values.each do |containers|
      DockerClient.destroy_container(containers.shift) until containers.empty?
    end
  end

  def self.config
    @config ||= CodeOcean::Config.new(:docker).read(erb: true)[:pool]
  end

  def self.remove_from_all_containers(container, execution_environment)
    @all_containers[execution_environment.id]-=[container]
    if(@containers[execution_environment.id].include?(container))
      @containers[execution_environment.id]-=[container]
    end
  end

  def self.add_to_all_containers(container, execution_environment)
    @all_containers[execution_environment.id]+=[container]
    if(!@containers[execution_environment.id].include?(container))
      @containers[execution_environment.id]+=[container]
    else
      Rails.logger.info('failed trying to add existing container ' + container.to_s)
    end
  end

  def self.create_container(execution_environment)
     container = DockerClient.create_container(execution_environment)
     container.status = 'available'
     container
  end

  def self.return_container(container, execution_environment)
    container.status = 'available'
    unless(@containers[execution_environment.id].include?(container))
      @containers[execution_environment.id].push(container)
    else
      Rails.logger.info('trying to return existing container ' + container.to_s)
    end
  end

  def self.get_container(execution_environment)
    if config[:active]
      container = @containers[execution_environment.id].try(:shift) || nil
      if(!container.nil?)
        if ((Time.now - container.start_time).to_i.abs > TIME_TILL_RESTART)
          # remove container from @all_containers
          Rails.logger.info('reinit container after time of life max  ' + container.to_s)
          remove_from_all_containers(container, execution_environment)

          # destroy container
          DockerClient.destroy_container(container)

          # create new container and add it to @all_containers. will be added to @containers on return_container
          container = create_container(execution_environment)
          add_to_all_containers(container, execution_environment)
          Rails.logger.info('new container is ' + container.to_s)
        end
        #container.status = 'used'
      end
      Rails.logger.info('fetched container  ' + container.to_s)
      Rails.logger.info('remaining avail. container  ' + @containers[execution_environment.id].size)
      Rails.logger.info('all container count' + @all_containers[execution_environment.id].size)
      container
    else
      create_container(execution_environment)
    end
  end

  def self.quantities
    @containers.map { |key, value| [key, value.length] }.to_h
  end

  def self.refill
    ExecutionEnvironment.where('pool_size > 0').each do |execution_environment|
      if config[:refill][:async]
        Concurrent::Future.execute { refill_for_execution_environment(execution_environment) }
      else
        refill_for_execution_environment(execution_environment)
      end
    end
  end

  def self.refill_for_execution_environment(execution_environment)
    refill_count = [execution_environment.pool_size - @all_containers[execution_environment.id].length, config[:refill][:batch_size]].min
    Rails.logger.info('adding' + refill_count.to_s + ' containers for  ' +  execution_environment.name )
    c = refill_count.times.map { create_container(execution_environment) }
    @containers[execution_environment.id] += c
    @all_containers[execution_environment.id] += c
    #refill_count.times.map { create_container(execution_environment) }
  end

  def self.start_refill_task
    @refill_task = Concurrent::TimerTask.new(execution_interval: config[:refill][:interval], run_now: false, timeout_interval: config[:refill][:timeout]) { refill }
    @refill_task.execute
  end
end
