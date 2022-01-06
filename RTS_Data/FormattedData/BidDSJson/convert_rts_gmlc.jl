import JSON3
import Logging
import Dates
import TimeSeries

using PowerSystems
import InfrastructureSystems
const IS = InfrastructureSystems


"""
Convert the RTS-GMLC system to ARPA-E format.

# Arguments
- `repo::AbstractString`: Local path to an RTS-GMLC git repository
- `file_path::AbstractString`: output JSON file
- `time_series_resolution::Dates.Period`: Resolution of time series. 5 minutes or 1 hour
- `try_deserialize::Bool`: Deserialize the PowerSystem.System if available.
"""
function convert_rts_gmlc_system(
    repo::AbstractString,
    file_path_network::AbstractString,
    file_path_time_series::AbstractString;
    time_series_resolution = Dates.Hour(1),
    console_level = Logging.Info,
    file_level = Logging.Info,
    try_deserialize = true,
)
    logger = configure_logging(
        console_level = console_level,
        file_level = file_level,
        filename = "rts_gmlc.log",
    )
    sys = create_rts_gmlc_system(
        repo,
        time_series_resolution = time_series_resolution,
        try_deserialize = try_deserialize,
    )
    data = to_arpa_e_format(sys)
    data_time_series = to_arpa_e_format_time_series(sys)
    open(file_path_network, "w") do io
        # JSON3.write(io, data)
        JSON3.pretty(io, data)
    end
    open(file_path_time_series, "w") do io
        # JSON3.write(io, data_time_series)
        JSON3.pretty(io, data_time_series)
    end

    @info "Serialized power system to $file_path_network"
    return
end

"""
Create a PowerSystems.System from the RTS-GMLC repository.

# Arguments
- `repo::String`: Local path to an RTS-GMLC git repository
- `time_series_resolution::Dates.Period`: Resolution of time series. 5 minutes or 1 hour
- `try_deserialize::Bool`: Deserialize the PowerSystem.System if available.

Refer to the `System` constructor for other allowed keyword arguments.
"""
function create_rts_gmlc_system(
    repo;
    time_series_resolution = Dates.Hour(1),
    try_deserialize = true,
    kwargs...,
)
    # serialized_file = "power_systems_rts_gmlc_sys.json"
    # if try_deserialize && isfile(serialized_file)
    #     return System(serialized_file; kwargs...)
    # end

    rts_data = joinpath(repo, "RTS_Data")
    src_data = joinpath(rts_data, "SourceData")
    siip_data = joinpath(rts_data, "FormattedData", "SIIP")
    data = PowerSystemTableData(
        src_data,
        100.0,
        joinpath(siip_data, "user_descriptors.yaml"),
        generator_mapping_file = joinpath(siip_data, "generator_mapping.yaml"),
        timeseries_metadata_file = joinpath(siip_data, "timeseries_pointers.json"),
    )
    sys = System(data; time_series_resolution = time_series_resolution, kwargs...)
    set_units_base_system!(sys, "system_base")
    # if try_deserialize
    #     to_json(sys, serialized_file, force = true)
    # end

    return sys
end

"""
Convert a PowerSystems.System to a dictionary in the ARPA-E format.
"""
function to_arpa_e_format(sys::System)
    data = Dict( 
                "bus" => [],
                "dispatchable_device" => [],
                "shunt" => [],
                "ac_line" => [],
                "two_winding_transformer" => [],
                "dc_line" => [],
                "regional_reserve" => [],
                "violation_cost" => Dict(
                    "p_vio_cost" => [[1000, 0.001], [1000000, 100.0]],
                    "q_vio_cost" => [[500, 0.001], [500000, 100.0]],
                    "p_bus_vio_cost" => [[0.0, 0.001], [1000000, 2.0]],
                    "q_bus_vio_cost" => [[0.0, 0.001], [1000000, 1.0]],
                    "v_bus_vio_cost" => [[0.0, 0.00001], [1000000, 0.5]],
                    "mva_branch_vio_cost" => [[500, 2.0]],
                ))

    for component in get_components(Component, sys)
        comp = to_arpa_e_format(component)
        if typeof(component) <: Line
            shunt_fr, shunt_to = to_arpa_e_format_shunt(component)
        end
        if !isnothing(comp)
            if typeof(component) <: Bus
                # comp["component_type"] = IS.strip_module_name(typeof(component))
                push!(data["bus"], comp)
            elseif typeof(component) <: Generator
                push!(data["dispatchable_device"], comp)
            elseif typeof(component) <: PowerLoad
                push!(data["dispatchable_device"], comp)
            elseif typeof(component) <: GenericBattery
                push!(data["dispatchable_device"], comp)
            elseif typeof(component) <: Reserve
                push!(data["regional_reserve"], comp)
            elseif typeof(component) <: Line
                push!(data["ac_line"], comp)
                push!(data["shunt"], shunt_fr)
                push!(data["shunt"], shunt_to)
            elseif typeof(component) <: TapTransformer
                push!(data["two_winding_transformer"], comp)
            elseif typeof(component) <: HVDCLine
                push!(data["dc_line"], comp)
            end
        end
    end

    network = Dict("network" => data)

    return network
end

function to_arpa_e_format(component::Component)
    @error "to_arpa_e_format is not implemented for $(typeof(component))"
    return
end

function to_arpa_e_format(component::Bus)
    data = Dict(
        "uid" => get_number(component),
        "base_nom_volt" => get_base_voltage(component),
        "type" => string(get_bustype(component)),
        "vm_lb" => get_voltage_limits(component).min,
        "vm_ub" => get_voltage_limits(component).max,
        "reserve_uid" => nothing,
        "latitude" => nothing,
        "longitude" => nothing,
    )
    area = get_area(component)
    zone = get_load_zone(component)
    data["area"] = isnothing(area) ? nothing : get_name(area)
    data["zone"] = isnothing(zone) ? nothing : get_name(zone)

    # add_time_series_data!(component, data)
    @info "Converted $(summary(component)) to ARPA-E format."
    return data
end

function _to_arpa_e_format_generator_common(component::Union{Generator, PowerLoad, GenericBattery})
    data = Dict(
        "uid" => get_name(component),
        "bus" => get_number(get_bus(component)),
        "vm_setpoint" => nothing,
        "startup_cost" => nothing,
        "shutdown_cost" => nothing,
        "energy_ub" => nothing,
        "energy_lb" => nothing,
        "pg_ext" => nothing,
        "config_num" => nothing,
        "config" => [],
        "storage_cap" => false,
    )

    # add_time_series_data!(component, data)
    @info "Converted $(summary(component)) to ARPA-E format."
    return data
end

function _to_arpa_e_format_generator_common_config(component::Union{Generator, PowerLoad, GenericBattery})
    data = Dict(
        "uid" => "default",
        "pg_ub" => 0.0,
        "qg_ub" => nothing,
        "pg_lb" => nothing,
        "qg_lb" => nothing,
        "cost" => nothing,
        "on_cost" => nothing,
        "in_service_time_lb" => nothing,
        "down_time_lb" => nothing,
        "pg_nom_ramp_ub" => nothing,
        "pg_nom_ramp_lb" => nothing,
        "storage_efficiency" => nothing,
        "Reg_Up_ub" => nothing,
        "Reg_Down_ub" => nothing,
        "Flex_Up_ub" => nothing,
        "Flex_Down_ub" => nothing,
        "Spin_Up_R1_ub" => nothing,
        "Spin_Up_R2_ub" => nothing,
        "Spin_Up_R3_ub" => nothing,
    )

    return data
end

function to_arpa_e_format(component::RenewableFix)
    data = _to_arpa_e_format_generator_common(component)
    data["config_num"] = 1

    config = _to_arpa_e_format_generator_common_config(component)
    config["pg_ub"] = get_max_active_power(component)
    config["qg_ub"] = get_max_reactive_power(component)

    push!(data["config"], config)

    return data
end

function to_arpa_e_format(component::RenewableDispatch)
    data = _to_arpa_e_format_generator_common(component)
    data["config_num"] = 1

    config = _to_arpa_e_format_generator_common_config(component)
    config["pg_ub"] = get_max_active_power(component)
    config["qg_ub"] = get_max_reactive_power(component)
    config["qg_lb"] = get_reactive_power_limits(component).min
    config["cost"] = [get_variable(get_operation_cost(component)).cost, get_max_active_power(component)]
    config["on_cost"] = get_fixed(get_operation_cost(component))
    for service in get_services(component)
        config[get_name(service) * "_ub"] = get_max_active_power(component)
    end

    push!(data["config"], config)

    return data
end

function to_arpa_e_format(component::ThermalStandard)
    data = _to_arpa_e_format_generator_common(component)
    data["config_num"] = 1

    config = _to_arpa_e_format_generator_common_config(component)
    config["pg_ub"] = get_max_active_power(component)
    config["qg_ub"] = get_max_reactive_power(component)
    config["pg_lb"] = get_active_power_limits(component).min
    config["qg_lb"] = get_reactive_power_limits(component).min
    base_power = PowerSystems.get_units_setting(component).base_value
    variable_cost_go = []
    variable_cost_psy = get_variable(get_operation_cost(component)).cost
    for b in 1:length(variable_cost_psy)
        if b == 1
            if length(variable_cost_psy[b]) == 1
                block = [get_variable(get_operation_cost(component)).cost, get_max_active_power(component)]
            else
                block = [variable_cost_psy[b][1]*base_power/variable_cost_psy[b][2], variable_cost_psy[b][2]/base_power]
            end
        else
            block = [(variable_cost_psy[b][1]-variable_cost_psy[b-1][1])*base_power/(variable_cost_psy[b][2]-variable_cost_psy[b-1][2]), (variable_cost_psy[b][2]-variable_cost_psy[b-1][2])/base_power]
        end
        push!(variable_cost_go, block)
    end
    config["cost"] = variable_cost_go
    config["on_cost"] = get_fixed(get_operation_cost(component))
    config["startup_cost"] = get_start_up(get_operation_cost(component))
    config["shutdown_cost"] = get_shut_down(get_operation_cost(component))
    config["in_service_time_lb"] = get_time_limits(component).up
    config["down_time_lb"] = get_time_limits(component).down
    config["pg_nom_ramp_ub"] = get_ramp_limits(component).up
    config["pg_nom_ramp_lb"] = get_ramp_limits(component).down
    for service in get_services(component)
        config[get_name(service) * "_ub"] = get_max_active_power(component)
    end

    push!(data["config"], config)

    return data
end

function to_arpa_e_format(component::HydroDispatch)
    data = _to_arpa_e_format_generator_common(component)
    data["config_num"] = 1

    config = _to_arpa_e_format_generator_common_config(component)
    config["pg_ub"] = get_max_active_power(component)
    config["qg_ub"] = get_max_reactive_power(component)
    config["pg_lb"] = get_active_power_limits(component).min
    config["qg_lb"] = get_reactive_power_limits(component).min
    config["cost"] = [get_variable(get_operation_cost(component)).cost, get_max_active_power(component)]
    config["on_cost"] = get_fixed(get_operation_cost(component))
    config["in_service_time_lb"] = get_time_limits(component).up
    config["down_time_lb"] = get_time_limits(component).down
    config["pg_nom_ramp_ub"] = get_ramp_limits(component).up
    config["pg_nom_ramp_lb"] = get_ramp_limits(component).down
    for service in get_services(component)
        config[get_name(service) * "_ub"] = get_max_active_power(component)
    end

    push!(data["config"], config)

    return data
end

function to_arpa_e_format(component::HydroEnergyReservoir)
    data = _to_arpa_e_format_generator_common(component)
    data["storage_cap"] = true
    data["pg_ext"] = get_inflow(component)
    data["energy_ub"] = get_storage_capacity(component)
    data["energy_lb"] = 0.0
    data["config_num"] = 1

    config = _to_arpa_e_format_generator_common_config(component)
    config["pg_ub"] = get_max_active_power(component)
    config["qg_ub"] = get_max_reactive_power(component)
    config["pg_lb"] = get_active_power_limits(component).min
    config["qg_lb"] = get_reactive_power_limits(component).min
    config["cost"] = [get_variable(get_operation_cost(component)).cost, get_max_active_power(component)]
    config["on_cost"] = get_fixed(get_operation_cost(component))
    config["in_service_time_lb"] = get_time_limits(component).up
    config["down_time_lb"] = get_time_limits(component).down
    config["pg_nom_ramp_ub"] = get_ramp_limits(component).up
    config["pg_nom_ramp_lb"] = get_ramp_limits(component).down
    for service in get_services(component)
        config[get_name(service) * "_ub"] = get_max_active_power(component)
    end

    push!(data["config"], config)

    return data
end

function to_arpa_e_format(component::PowerLoad)
    data = _to_arpa_e_format_generator_common(component)
    base_power = PowerSystems.get_units_setting(component).base_value
    data["config_num"] = 1

    config = _to_arpa_e_format_generator_common_config(component)
    config["pg_lb"] = -get_max_active_power(component)
    config["qg_lb"] = -get_max_reactive_power(component)
    config["cost"] = [3000*base_power, -get_max_active_power(component)]

    push!(data["config"], config)
    return data
end

function to_arpa_e_format(component::Reserve)
    data = Dict(
        "uid" => get_name(component),
        "type" => get_name(component),
        "reserve_required" => get_requirement(component),
    )

    # add_time_series_data!(component, data)
    @info "Converted $(summary(component)) to ARPA-E format."
    return data
end

function to_arpa_e_format(component::GenericBattery)
    data = _to_arpa_e_format_generator_common(component)
    data["config_num"] = 2
    data["energy_ub"] = get_state_of_charge_limits(component).max
    data["energy_lb"] = get_state_of_charge_limits(component).min
    data["storage_cap"] = true

    config_charge = _to_arpa_e_format_generator_common_config(component)
    config_charge["uid"] = "charging"
    config_charge["pg_ub"] = get_input_active_power_limits(component).max
    config_charge["pg_lb"] = get_input_active_power_limits(component).min
    config_charge["storage_efficiency"] = get_efficiency(component).in

    config_discharge = _to_arpa_e_format_generator_common_config(component)
    config_discharge["uid"] = "discharging"
    config_discharge["pg_ub"] = get_output_active_power_limits(component).max
    config_discharge["pg_lb"] = get_output_active_power_limits(component).min
    config_discharge["storage_efficiency"] = get_efficiency(component).out

    push!(data["config"], config_charge)
    push!(data["config"], config_discharge)

    # add_time_series_data!(component, data)
    @info "Converted $(summary(component)) to ARPA-E format."
    return data
end

function to_arpa_e_format(component::Line)
    data = Dict(
        "uid" => get_name(component),
        "fr_bus" => get_number(get_arc(component).from),
        "to_bus" => get_number(get_arc(component).to),
        "r" => get_r(component),
        "x" => get_x(component),
        "b_fr" => get_b(component).from,
        "b_to" => get_b(component).to,
        "mva_ub_nom" => get_rate(component),
    )

    # add_time_series_data!(component, data)
    @info "Converted $(summary(component)) to ARPA-E format."
    return data
end

function to_arpa_e_format_shunt(component::Line)
    data_fr = Dict(
        "uid" => get_name(component)*"_fr",
        "bus" => get_number(get_arc(component).from),
        "bs" => get_b(component).from,
    )

    data_to = Dict(
        "uid" => get_name(component)*"_to",
        "bus" => get_number(get_arc(component).to),
        "bs" => get_b(component).to,
    )

    # add_time_series_data!(component, data)
    @info "Converted $(summary(component)) to ARPA-E format."
    return data_fr, data_to
end

function to_arpa_e_format(component::TapTransformer)
    data = Dict(
        "uid" => get_name(component),
        "fr_bus" => get_number(get_arc(component).from),
        "to_bus" => get_number(get_arc(component).to),
        "r" => get_r(component),
        "x" => get_x(component),
        "tm" => get_tap(component),
        "mva_ub_nom" => get_rate(component),
    )

    # add_time_series_data!(component, data)
    @info "Converted $(summary(component)) to ARPA-E format."
    return data
end

function to_arpa_e_format(component::HVDCLine)
    data = Dict(
        "uid" => get_name(component),
        "fr_bus" => get_number(get_arc(component).from),
        "to_bus" => get_number(get_arc(component).to),
        "pdc_ub" => get_active_power_limits_from(component).max,
        "pdc_lb" => get_active_power_limits_from(component).min,
        "qdc_ub" => get_reactive_power_limits_from(component).max,
        "qdc_lb" => get_reactive_power_limits_from(component).min,
    )

    # add_time_series_data!(component, data)
    @info "Converted $(summary(component)) to ARPA-E format."
    return data
end

# function add_time_series_data!(component::Component, data::Dict)
#     data["time_series"] = []
#     !has_time_series(component) && return

#     for time_series in get_time_series_multiple(component)
#         time_series isa Forecast && error("Forecasts are unexpected")
#         ta = get_time_series_array(component, time_series)
#         obj = Dict(
#             "name" => get_name(time_series),
#             "resolution" => Dates.Second(get_resolution(time_series)).value,  # TODO another unit?
#             "timestamps" => TimeSeries.timestamp(ta),
#             "values" => TimeSeries.values(ta),
#         )
#         push!(data["time_series"], obj)
#         @info "Added time series $(get_name(time_series)) to $(summary(component))"
#     end
# end

function to_arpa_e_format_time_series(sys::System)
    data = Dict(
                "time_data" => Dict("start_time" => TimeSeries.DateTime("2020-01-01T00:00:00"), "time_period" => 24, "interval_duration" => 1.0),
                "dispatchable_device" => [],
                "ac_line" => [],
                "two_winding_transformer" => [],
                "dc_line" => [],
                "regional_reserve" => [])

    for component in get_components(Component, sys)
        comp_ts = to_arpa_e_format_time_series(component, data["time_data"]["start_time"], data["time_data"]["time_period"])
        if !isnothing(comp_ts)
            if typeof(component) <: Generator
                push!(data["dispatchable_device"], comp_ts)
            elseif typeof(component) <: PowerLoad
                push!(data["dispatchable_device"], comp_ts)
            elseif typeof(component) <: Reserve
                push!(data["regional_reserve"], comp_ts)
            end
        end
    end

    time_series_data = Dict("time_series_input" => data)

    return time_series_data
end

function to_arpa_e_format_time_series(component::Component, start_time::TimeSeries.DateTime, time_period::Int64)
    @error "to_arpa_e_format_time_series is not implemented for $(typeof(component))"
    return
end

function to_arpa_e_format_time_series(component::Union{Generator}, start_time::TimeSeries.DateTime, time_period::Int64)
    !has_time_series(component) && return

    ts = get_time_series_array(
        SingleTimeSeries,
        component,
        "max_active_power",
        start_time = start_time,
        len = time_period
    )
    ta = TimeSeries.values(ts)

    data = Dict(
        "uid" => get_name(component),
        "on_status_ub" => ones(time_period),
        "on_status_lb" => zeros(time_period),
        "config" => [
            Dict(
                "uid" => "default",
                "pg_ub" => ta,
            )
        ]
    )

    @info "Converted max_active_power time series of $(summary(component)) to ARPA-E format."
    return data
end

function to_arpa_e_format_time_series(component::Union{PowerLoad}, start_time::TimeSeries.DateTime, time_period::Int64)
    !has_time_series(component) && return

    ts = get_time_series_array(
        SingleTimeSeries,
        component,
        "max_active_power",
        start_time = start_time,
        len = time_period
    )
    ta = TimeSeries.values(ts)

    data = Dict(
        "uid" => get_name(component),
        "on_status_ub" => ones(time_period),
        "on_status_lb" => zeros(time_period),
        "config" => [
            Dict(
                "uid" => "default",
                "pg_lb" => -ta
            )
        ]
    )

    @info "Converted max_active_power time series of $(summary(component)) to ARPA-E format."
    return data
end

function to_arpa_e_format_time_series(component::Reserve, start_time::TimeSeries.DateTime, time_period::Int64)
    !has_time_series(component) && return

    ts = get_time_series_array(
        SingleTimeSeries,
        component,
        "requirement",
        start_time = start_time,
        len = time_period
    )
    ta = TimeSeries.values(ts)

    data = Dict(
        "uid" => get_name(component),
        "reserve_requirement" => ta,
    )

    @info "Converted requirement time series of $(summary(component)) to ARPA-E format."
    return data
end


# run JSON translation script
repo = "C://Users//nguo//Documents//GitHub//Bid-DS//RTS-GMLC"
file_path_network = joinpath(repo, "RTS_Data//FormattedData//BidDSJson", "PSY_RTS_GMLC_network.json")
file_path_time_series = joinpath(repo, "RTS_Data//FormattedData//BidDSJson", "PSY_RTS_GMLC_timeseries.json")
convert_rts_gmlc_system(repo, file_path_network, file_path_time_series)









# for testing purposes
# sys = create_rts_gmlc_system(repo)
# collect(get_components(HydroDispatch, sys))
# A = get_component(GenericBattery, sys, "313_STORAGE_1")
# A = get_component(ThermalStandard, sys, "322_CT_6")
# A = get_component(HydroEnergyReservoir, sys, "215_HYDRO_3")
# A = get_component(HydroDispatch, sys, "201_HYDRO_4")

# ts = get_time_series_array(
#     SingleTimeSeries,
#     A,
#     "max_active_power",
#     start_time = TimeSeries.DateTime("2020-01-01T00:00:00"),
#     len = 24
# )
# ta = TimeSeries.values(ts)