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
    file_path::AbstractString;
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
    open(file_path, "w") do io
        JSON3.write(io, data)
    end

    @info "Serialized power system to $file_path"
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
    serialized_file = "power_systems_rts_gmlc_sys.json"
    if try_deserialize && isfile(serialized_file)
        return System(serialized_file; kwargs...)
    end

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
    if try_deserialize
        to_json(sys, serialized_file, force = true)
    end

    return sys
end

"""
Convert a PowerSystems.System to a dictionary in the ARPA-E format.
"""
function to_arpa_e_format(sys::System)
    data = Dict("base_power" => get_base_power(sys), "components" => [])
    for component in get_components(Component, sys)
        comp = to_arpa_e_format(component)
        if !isnothing(comp)
            comp["component_type"] = IS.strip_module_name(typeof(component))
            push!(data["components"], comp)
        end
    end

    return data
end

function to_arpa_e_format(component::Component)
    @error "to_arpa_e_format is not implemented for $(typeof(component))"
    return
end

function to_arpa_e_format(component::Bus)
    data = Dict(
        "uid" => get_name(component),  # TODO: bus number with get_number(bus) instead?
        "base_nom_volt" => get_base_voltage(component),
        "type" => string(get_bustype(component)),  # TODO: may need capitalization changes
        "vm_lb" => get_voltage_limits(component).min,
        "vm_ub" => get_voltage_limits(component).max,
    )
    area = get_area(component)
    zone = get_load_zone(component)
    data["area"] = isnothing(area) ? nothing : get_name(area)
    data["zone"] = isnothing(zone) ? nothing : get_name(zone)

    add_time_series_data!(component, data)
    @info "Converted $(summary(component)) to ARPA-E format."
    return data
end

function _to_arpa_e_format_generator_common(component::Generator)
    data = Dict(
        "uid" => get_name(component),
        "bus" => get_name(get_bus(component)),  # TODO: bus number with get_number(bus) instead?
        "pg" => get_active_power(component),
        "qg" => get_reactive_power(component),
        "pg_ub" => get_max_active_power(component),
        "qg_ub" => get_max_reactive_power(component),
        "pg_lb" => nothing,
        "qg_lb" => nothing,
    )

    add_time_series_data!(component, data)
    @info "Converted $(summary(component)) to ARPA-E format."
    return data
end

function to_arpa_e_format(component::RenewableGen)
    return _to_arpa_e_format_generator_common(component)
end

function to_arpa_e_format(component::ThermalGen)
    data = _to_arpa_e_format_generator_common(component)
    data["pg_lb"] = get_active_power_limits(component).min
    data["qg_lb"] = get_reactive_power_limits(component).min
    return data
end

function add_time_series_data!(component::Component, data::Dict)
    data["time_series"] = []
    !has_time_series(component) && return

    for time_series in get_time_series_multiple(component)
        time_series isa Forecast && error("Forecasts are unexpected")
        ta = get_time_series_array(component, time_series)
        obj = Dict(
            "name" => get_name(time_series),
            "resolution" => Dates.Second(get_resolution(time_series)).value,  # TODO another unit?
            "timestamps" => TimeSeries.timestamp(ta),
            "values" => TimeSeries.values(ta),
        )
        push!(data["time_series"], obj)
        @info "Added time series $(get_name(time_series)) to $(summary(component))"
    end
end




