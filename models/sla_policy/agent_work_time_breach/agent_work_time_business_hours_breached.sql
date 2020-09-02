{{ config(enabled=enabled_vars(['using_sla_policy','using_schedules'])) }}

-- AGENT WORK TIME
-- This is complicated, as SLAs minutes are only counted while the ticket is in 'new' or 'open' status.

-- Additionally, for business hours, only 'new' or 'open' status hours are counted if they are also during business hours
with agent_work_time_filtered_statuses as (

  select *
  from {{ ref('agent_work_time_filtered_statuses') }}
  where in_business_hours = 'true'

), schedule as (

  select * 
  from {{ ref('stg_zendesk_schedule') }}

), ticket_schedules as (

  select * 
  from {{ ref('ticket_schedules') }}
  
-- cross schedules with work time
), ticket_status_crossed_with_schedule as (
  
    select
      agent_work_time_filtered_statuses.ticket_id,
      agent_work_time_filtered_statuses.sla_applied_at,
--       agent_work_time_filtered_statuses.ticket_created_at,
      agent_work_time_filtered_statuses.target,      
      ticket_schedules.schedule_id,
      greatest(valid_starting_at, schedule_created_at) as valid_starting_at,
      least(valid_ending_at, schedule_invalidated_at) as valid_ending_at
    from agent_work_time_filtered_statuses
    left join ticket_schedules
      on agent_work_time_filtered_statuses.ticket_id = ticket_schedules.ticket_id
    where timestamp_diff(least(valid_ending_at, schedule_invalidated_at), greatest(valid_starting_at, schedule_created_at), second) > 0


), ticket_full_solved_time as (

    select 
      ticket_status_crossed_with_schedule.*,
      round(timestamp_diff(
              ticket_status_crossed_with_schedule.valid_starting_at, 
              timestamp_trunc(
                  ticket_status_crossed_with_schedule.valid_starting_at, 
                  week), 
              second)/60,
            0) as valid_starting_at_in_minutes_from_week,
      round(timestamp_diff(
              ticket_status_crossed_with_schedule.valid_ending_at, 
              ticket_status_crossed_with_schedule.valid_starting_at, 
              second)/60,
            0) as raw_delta_in_minutes
    from ticket_status_crossed_with_schedule
    group by 1, 2, 3, 4, 5, 6, 7

), weekly_period_agent_work_time as (

    select 
      ticket_id,
      sla_applied_at,
      valid_starting_at,
      valid_ending_at,
      target,
      valid_starting_at_in_minutes_from_week,
      raw_delta_in_minutes,
      week_number,
      schedule_id,
      greatest(0, valid_starting_at_in_minutes_from_week - week_number * (7*24*60)) as ticket_week_start_time_minute,
      least(valid_starting_at_in_minutes_from_week + raw_delta_in_minutes - week_number * (7*24*60), (7*24*60)) as ticket_week_end_time_minute
    from ticket_full_solved_time,
        unnest(generate_array(0, floor((valid_starting_at_in_minutes_from_week + raw_delta_in_minutes) / (7*24*60)), 1)) as week_number

), intercepted_periods_agent as (
  
    select 
      weekly_period_agent_work_time.ticket_id,
      weekly_period_agent_work_time.sla_applied_at,
      weekly_period_agent_work_time.target,
      weekly_period_agent_work_time.valid_starting_at,
      weekly_period_agent_work_time.valid_ending_at,
      weekly_period_agent_work_time.week_number,
      weekly_period_agent_work_time.ticket_week_start_time_minute,
      weekly_period_agent_work_time.ticket_week_end_time_minute,
      schedule.start_time_utc as schedule_start_time,
      schedule.end_time_utc as schedule_end_time,
      least(ticket_week_end_time_minute, schedule.end_time_utc) - greatest(weekly_period_agent_work_time.ticket_week_start_time_minute, schedule.start_time_utc) as scheduled_minutes,
    from weekly_period_agent_work_time
    join schedule on ticket_week_start_time_minute <= schedule.end_time_utc 
      and ticket_week_end_time_minute >= schedule.start_time_utc
      and weekly_period_agent_work_time.schedule_id = schedule.schedule_id

), intercepted_periods_with_running_total as (
  
    select 
      *,
      sum(scheduled_minutes) over 
        (partition by ticket_id, sla_applied_at order by valid_starting_at, week_number, schedule_end_time)
        as running_total_scheduled_minutes

    from intercepted_periods_agent

), intercepted_periods_agent_with_breach_flag as (
  select 
    intercepted_periods_with_running_total.*,
    target - running_total_scheduled_minutes as remaining_target_minutes,
    case when (target - running_total_scheduled_minutes) = 0 then true
       when (target - running_total_scheduled_minutes) < 0 
        and 
          (lag(target - running_total_scheduled_minutes) over
          (partition by ticket_id, sla_applied_at order by valid_starting_at, week_number, schedule_end_time) > 0 
          or 
          lag(target - running_total_scheduled_minutes) over
          (partition by ticket_id, sla_applied_at order by valid_starting_at, week_number, schedule_end_time) is null) 
          then true else false end as is_breached_during_schedule
          
  from  intercepted_periods_with_running_total

), intercepted_periods_agent_filtered as (

  select
    *,
    (remaining_target_minutes + scheduled_minutes) as breach_minutes,
    greatest(ticket_week_start_time_minute, schedule_start_time) + (remaining_target_minutes + scheduled_minutes) as breach_minutes_from_week
  from intercepted_periods_agent_with_breach_flag
  where is_breached_during_schedule
  
-- Now we have agent work time business hours breached_at timestamps. Only SLAs that have been breached will appear in this list, otherwise
-- would be filtered out in the above
), agent_work_business_breach as (
  
  select 
    *,
    timestamp_add(
      timestamp_trunc(valid_starting_at, week),
      interval cast(((7*24*60) * week_number) + breach_minutes_from_week as int64) minute) as breached_at
  from intercepted_periods_agent_filtered

) 

select * 
from agent_work_business_breach