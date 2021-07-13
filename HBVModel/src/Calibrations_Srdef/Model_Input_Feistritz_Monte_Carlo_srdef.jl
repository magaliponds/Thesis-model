using Distributed
@everywhere using Dates
@everywhere using DelimitedFiles
@everywhere using CSV
#@everywhere using Plots
@everywhere using Statistics
@everywhere using DocStringExtensions
using DataFrames
@everywhere using Random

@everywhere module_dir = "/Users/magali/Documents/1. Master/1.4 Thesis/02 Execution/01 Model Sarah/HBVModel/src/"
@everywhere push!(LOAD_PATH, $module_dir)

# load list of structs
@everywhere include(module_dir*"Model_Core/structs.jl")
# load components of models represented by buckets
@everywhere include(module_dir*"Model_Core/processes_buckets.jl")
# load functions that combine all components of one HRU
@everywhere include(module_dir*"Model_Core/elevations.jl")
# load functions for combining all HRUs and for running the model
@everywhere include(module_dir*"Model_Core/allHRU.jl")
# load function for running model which just returns the necessary output for calibration
@everywhere include(module_dir*"Model_Core/run_model.jl")
# load functions for preprocessing temperature and precipitation data
@everywhere include(module_dir*"Model_Core/Preprocessing.jl")
# load functions for calculating the potential evaporation
@everywhere include(module_dir*"Model_Core/Potential_Evaporation.jl")
# load objective functionsM
@everywhere include(module_dir*"Model_Core/ObjectiveFunctions.jl")
# load parameterselection
@everywhere include(module_dir*"Model_Core/parameterselection.jl")
# load running model in several precipitation zones
@everywhere include(module_dir*"Model_Core/runmodel_Prec_Zones.jl")


@everywhere function run_MC(ID, nmax, min_srdef_Grass, min_srdef_Forest, min_srdef_Bare, min_srdef_Rip, max_srdef_Grass, max_srdef_Forest, max_srdef_Bare, max_srdef_Rip, ep_method, timeframes)
        local_path = "/Users/magali/Documents/1. Master/1.4 Thesis/02 Execution/01 Model Sarah/"
        # ------------ CATCHMENT SPECIFIC INPUTS----------------
        ID_Prec_Zones = [109967]
        # size of the area of precipitation zones
        Area_Zones = [115496400.]
        Area_Catchment = sum(Area_Zones)
        Area_Zones_Percent = Area_Zones / Area_Catchment

        Snow_Threshold = 10000
        Height_Threshold = 10000

        Mean_Elevation_Catchment = 900 # in reality 917
        # two last entries of array are height of temp measurement
        Elevations_Catchment = Elevations(200.0, 400.0, 1600.0, 488., 488.)
        Sunhours_Vienna = [8.83, 10.26, 11.95, 13.75, 15.28, 16.11, 15.75, 14.36, 12.63, 10.9, 9.28, 8.43]
        # where to skip to in data file of precipitation measurements
        Skipto = [24]
        # get the areal percentage of all elevation zones in the HRUs in the precipitation zones
        Areas_HRUs =  CSV.read(local_path*"HBVModel/Feistritz/HBV_Area_Elevation.csv", DataFrame, skipto=2, decimal='.', delim = ',')
        # get the percentage of each HRU of the precipitation zone
        Percentage_HRU = CSV.read(local_path*"HBVModel/Feistritz/HRU_Prec_Zones.csv", DataFrame, header=[1], decimal='.', delim = ',')
        Elevation_Catchment = convert(Vector, Areas_HRUs[2:end,1])
        startyear = 1983
        endyear = 2005
        # timeperiod for which model should be run (look if timeseries of data has same length)
        Timeseries = collect(Date(startyear, 1, 1):Day(1):Date(endyear,12,31))

        #------------ TEMPERATURE AND POT. EVAPORATION CALCULATIONS ---------------------
        #Temperature is the same in whole catchment
        Temperature = CSV.read(local_path*"HBVModel/Feistritz/prenner_tag_10510.dat", DataFrame, header = true, skipto = 3, delim = ' ', ignorerepeated = true)

        # get data for 20 years: from 1987 to end of 2006
        # from 1986 to 2005 13669: 20973
        #hydrological year 13577:20881
        Temperature = dropmissing(Temperature)
        Temperature_Array = Temperature.t / 10
        #Precipitation_9900 = Temperature.nied / 10
        Timeseries_Temp = Date.(Temperature.datum, Dates.DateFormat("yyyymmdd"))
        startindex = findfirst(isequal(Date(startyear, 1, 1)), Timeseries_Temp)
        endindex = findfirst(isequal(Date(endyear, 12, 31)), Timeseries_Temp)
        Temperature_Daily = Temperature_Array[startindex[1]:endindex[1]]
        Timeseries_Temp = Timeseries_Temp[startindex[1]:endindex[1]]

        @assert Timeseries_Temp == Timeseries
        #println("works", "\n")
        Elevation_Zone_Catchment, Temperature_Elevation_Catchment, Total_Elevationbands_Catchment = gettemperatureatelevation(Elevations_Catchment, Temperature_Daily)
        # get the temperature data at the mean elevation to calculate the mean potential evaporation
        Temperature_Mean_Elevation = Temperature_Elevation_Catchment[:,findfirst(x-> x==Mean_Elevation_Catchment, Elevation_Zone_Catchment)]
        Potential_Evaporation = getEpot_Daily_thornthwaite(Temperature_Mean_Elevation, Timeseries, Sunhours_Vienna)

        # ------------ LOAD OBSERVED DISCHARGE DATA ----------------
        Discharge = CSV.read(local_path*"HBVModel/Feistritz/Q-Tagesmittel-214353.csv", DataFrame, header= false, skipto=388, decimal=',', delim = ';', types=[String, Float64])
        Discharge = Matrix(Discharge)
        startindex = findfirst(isequal("01.01."*string(startyear)*" 00:00:00"), Discharge)
        endindex = findfirst(isequal("31.12."*string(endyear)*" 00:00:00"), Discharge)
        Observed_Discharge = Array{Float64,1}[]
        push!(Observed_Discharge, Discharge[startindex[1]:endindex[1],2])
        Observed_Discharge = Observed_Discharge[1]
        # transfer Observed Discharge to mm/d
        Observed_Discharge = Observed_Discharge * 1000 / Area_Catchment * (3600 * 24)
        # ------------ LOAD TIMESERIES DATA AS DATES ------------------
        #Timeseries = Date.(Discharge[startindex[1]:endindex[1],1], Dates.DateFormat("d.m.y H:M:S"))
        firstyear = Dates.year(Timeseries[1])
        lastyear = Dates.year(Timeseries[end])

        # ------------- LOAD OBSERVED SNOW COVER DATA PER PRECIPITATION ZONE ------------
        # find day wehere 2000 starts for snow cover calculations
        start2000 = findfirst(x -> x == Date(2000, 01, 01), Timeseries)
        length_2000_end = length(Timeseries) - start2000 + 1
        observed_snow_cover = Array{Float64,2}[]
        for ID in ID_Prec_Zones
                current_observed_snow = readdlm(local_path*"HBVModel/Feistritz/snow_cover_fixed_Zone"*string(ID)*".csv",',', Float64)
                current_observed_snow = current_observed_snow[1:length_2000_end,3: end]
                push!(observed_snow_cover, current_observed_snow)
        end

        # ------------- LOAD PRECIPITATION DATA OF EACH PRECIPITATION ZONE ----------------------
        # get elevations at which precipitation was measured in each precipitation zone
        Elevations_109967= Elevations(200., 400., 1600., 563.,488.)
        # Elevations_111815 = Elevations(200, 600, 2400, 890., 648.)
        # Elevations_9900 = Elevations(200, 600, 2400, 648., 648.)
        Elevations_All_Zones = [Elevations_109967]

        #get the total discharge
        Total_Discharge = zeros(length(Temperature_Daily))
        Inputs_All_Zones = Array{HRU_Input, 1}[]
        Storages_All_Zones = Array{Storages, 1}[]
        Precipitation_All_Zones = Array{Float64, 2}[]
        Precipitation_Gradient = 0.0
        Elevation_Percentage = Array{Float64, 1}[]
        Nr_Elevationbands_All_Zones = Int64[]
        Elevations_Each_Precipitation_Zone = Array{Float64, 1}[]

        for i in 1: length(ID_Prec_Zones)
                Precipitation = CSV.read(local_path*"HBVModel/Feistritz/N-Tagessummen-"*string(ID_Prec_Zones[i])*".csv", DataFrame, header= false, skipto=Skipto[i], missingstring = "L\xfccke", decimal=',', delim = ';')
                Precipitation_Array = Matrix(Precipitation)
                startindex = findfirst(isequal("01.01."*string(startyear)*" 07:00:00   "), Precipitation_Array)
                endindex = findfirst(isequal("31.12."*string(endyear)*" 07:00:00   "), Precipitation_Array)
                Precipitation_Array = Precipitation_Array[startindex[1]:endindex[1],:]
                Precipitation_Array[:,1] = Date.(Precipitation_Array[:,1], Dates.DateFormat("d.m.y H:M:S   "))
                # find duplicates and remove them
                df = DataFrame(Precipitation_Array, :auto)
                df = unique!(df)
                # drop missing values
                df = dropmissing(df)
                Precipitation_Array = Matrix(df)
                Elevation_HRUs, Precipitation, Nr_Elevationbands = getprecipitationatelevation(Elevations_All_Zones[i], Precipitation_Gradient, Precipitation_Array[:,2])
                push!(Precipitation_All_Zones, Precipitation)
                push!(Nr_Elevationbands_All_Zones, Nr_Elevationbands)
                push!(Elevations_Each_Precipitation_Zone, Elevation_HRUs)



                index_HRU = (findall(x -> x==ID_Prec_Zones[i], Areas_HRUs[1,2:end]))
                # for each precipitation zone get the relevant areal extentd
                Current_Areas_HRUs = Matrix(Areas_HRUs[2: end, index_HRU])
                # the elevations of each HRU have to be known in order to get the right temperature data for each elevation
                Area_Bare_Elevations, Bare_Elevation_Count = getelevationsperHRU(Current_Areas_HRUs[:,1], Elevation_Catchment, Elevation_HRUs)
                Area_Forest_Elevations, Forest_Elevation_Count = getelevationsperHRU(Current_Areas_HRUs[:,2], Elevation_Catchment, Elevation_HRUs)
                Area_Grass_Elevations, Grass_Elevation_Count = getelevationsperHRU(Current_Areas_HRUs[:,3], Elevation_Catchment, Elevation_HRUs)

                Area_Rip_Elevations, Rip_Elevation_Count = getelevationsperHRU(Current_Areas_HRUs[:,4], Elevation_Catchment, Elevation_HRUs)
                #print(Bare_Elevation_Count, Forest_Elevation_Count, Grass_Elevation_Count, Rip_Elevation_Count)
                # println((Area_Bare_Elevations), " ", Bare_Elevation_Count,"\n")
                # println((Area_Forest_Elevations), " ", Forest_Elevation_Count,"\n")
                Area_Bare_Elevations = [0.0]
                Bare_Elevation_Count = [1]
                @assert 0.999 <= sum(Area_Bare_Elevations) <= 1.0001 || sum(Area_Bare_Elevations) == 0

                @assert 0.999 <= sum(Area_Forest_Elevations) <= 1.0001
                @assert 0.999 <= sum(Area_Grass_Elevations) <= 1.0001
                @assert 0.999 <= sum(Area_Rip_Elevations) <= 1.0001

                Area = Area_Zones[i]
                Current_Percentage_HRU = Percentage_HRU[:,1 + i]/Area
                # calculate percentage of elevations
                Perc_Elevation = zeros(Total_Elevationbands_Catchment)
                for j in 1 : Total_Elevationbands_Catchment
                        for h in 1:4
                                Perc_Elevation[j] += Current_Areas_HRUs[j,h] * Current_Percentage_HRU[h]
                        end
                end
                Perc_Elevation = Perc_Elevation[(findall(x -> x!= 0, Perc_Elevation))]
                @assert 0.99 <= sum(Perc_Elevation) <= 1.01
                push!(Elevation_Percentage, Perc_Elevation)
                #println(Current_Percentage_HRU[1], zeros(length(Bare_Elevation_Count)) , Bare_Elevation_Count, length(Bare_Elevation_Count[1]), 0, [0], 0, [0], 0, 0)

                # calculate the inputs once for every precipitation zone because they will stay the same during the Monte Carlo Sampling
                bare_input = HRU_Input(Area_Bare_Elevations, Current_Percentage_HRU[1],zeros(length(Bare_Elevation_Count)) , Bare_Elevation_Count, length(Bare_Elevation_Count), (Elevations_All_Zones[i].Min_elevation + 100, Elevations_All_Zones[i].Max_elevation - 100), (Snow_Threshold, Height_Threshold), 0, [0], 0, [0], 0, 0)
                forest_input = HRU_Input(Area_Forest_Elevations, Current_Percentage_HRU[2], zeros(length(Forest_Elevation_Count)) , Forest_Elevation_Count, length(Forest_Elevation_Count), (Elevations_All_Zones[i].Min_elevation + 100, Elevations_All_Zones[i].Max_elevation - 100), (Snow_Threshold, Height_Threshold), 0, [0], 0, [0],  0, 0)
                grass_input = HRU_Input(Area_Grass_Elevations, Current_Percentage_HRU[3], zeros(length(Grass_Elevation_Count)) , Grass_Elevation_Count, length(Grass_Elevation_Count),  (Elevations_All_Zones[i].Min_elevation + 100, Elevations_All_Zones[i].Max_elevation - 100), (Snow_Threshold, Height_Threshold),0, [0], 0, [0],  0, 0)
                rip_input = HRU_Input(Area_Rip_Elevations, Current_Percentage_HRU[4], zeros(length(Rip_Elevation_Count)) , Rip_Elevation_Count, length(Rip_Elevation_Count), (Elevations_All_Zones[i].Min_elevation + 100, Elevations_All_Zones[i].Max_elevation - 100), (Snow_Threshold, Height_Threshold), 0, [0], 0, [0],  0, 0)

                all_inputs = [bare_input, forest_input, grass_input, rip_input]
                #print(typeof(all_inputs))
                push!(Inputs_All_Zones, all_inputs)

                bare_storage = Storages(0, zeros(length(Bare_Elevation_Count)), zeros(length(Bare_Elevation_Count)), zeros(length(Bare_Elevation_Count)), 0)
                forest_storage = Storages(0, zeros(length(Forest_Elevation_Count)), zeros(length(Forest_Elevation_Count)), zeros(length(Bare_Elevation_Count)), 0)
                grass_storage = Storages(0, zeros(length(Grass_Elevation_Count)), zeros(length(Grass_Elevation_Count)), zeros(length(Bare_Elevation_Count)), 0)
                rip_storage = Storages(0, zeros(length(Rip_Elevation_Count)), zeros(length(Rip_Elevation_Count)), zeros(length(Bare_Elevation_Count)), 0)

                all_storages = [bare_storage, forest_storage, grass_storage, rip_storage]
                push!(Storages_All_Zones, all_storages)
        end
        # ---------------- CALCULATE OBSERVED OBJECTIVE FUNCTIONS -------------------------------------
        # calculate the sum of precipitation of all precipitation zones to calculate objective functions
        #Total_Precipitation = Precipitation_All_Zones[1][:,1]*Area_Zones_Percent[1] + Precipitation_All_Zones[2][:,1]*Area_Zones_Percent[2] + Precipitation_All_Zones[3][:,1]*Area_Zones_Percent[3]
        Total_Precipitation = Precipitation_All_Zones[1][:,1]
        #check_waterbalance = hcat(Total_Precipitation, Observed_Discharge, Potential_Evaporation)

        # don't consider spin up time for calculation of Goodness of Fit
        # end of spin up time is 3 years after the start of the calibration and start in the month October
        index_spinup = findfirst(x -> Dates.year(x) == firstyear + 2 && Dates.month(x) == 10, Timeseries)
        # evaluations chouls alsways contain whole year
        index_lastdate = findfirst(x -> Dates.year(x) == lastyear && Dates.month(x) == 10, Timeseries) - 1


        # delet days
        delete_days = readdlm(local_path*"HBVModel/Feistritz/Delete_Days.csv", ',', Int)
        Timeseries_Obj = Timeseries[index_spinup: index_lastdate]
        deleteat!(Timeseries_Obj, delete_days)
        Observed_Discharge_Obj = Observed_Discharge[index_spinup: index_lastdate]
        observed_AC_1day = autocorrelation(Observed_Discharge_Obj, 1)
        observed_AC_90day = autocorrelationcurve(Observed_Discharge_Obj, 90)[1]

        deleteat!(Observed_Discharge_Obj, delete_days)
        Total_Precipitation_Obj = Total_Precipitation[index_spinup: index_lastdate]
        deleteat!(Total_Precipitation_Obj, delete_days)
        #calculating the observed FDC; AC; Runoff
        observed_FDC = flowdurationcurve(log.(Observed_Discharge_Obj))[1]
        # observed_AC_1day = autocorrelation(Observed_Discharge_Obj, 1)
        # observed_AC_90day = autocorrelationcurve(Observed_Discharge_Obj, 90)[1]
        observed_monthly_runoff = monthlyrunoff(Area_Catchment, Total_Precipitation_Obj, Observed_Discharge_Obj, Timeseries_Obj)[1]

        # ---------------- START MONTE CARLO SAMPLING ------------------------
        #All_Goodness_new = []
        All_Goodness = zeros(29)
        #All_Parameter_Sets = Array{Any, 1}[]
        GWStorage = 70.0
        print("worker ", ID, " preparation finished", "\n")
        count = 1
        number_Files = 0
        # best_calibrations = readdlm("/Users/magali/Documents/1. Master/1.4 Thesis/02 Execution/01 Model Sarah/Calibrations/Feistritz/Feistritz_1400000_1.csv", ',')
        # best_calibrations = readdlm("/Users/magali/Documents/1. Master/1.4 Thesis/02 Execution/01 Model Sarah/Calibrations/Feistritz_less_dates/Feistritz_Parameterfit_All_runs_best_100000.csv", ',')
        # index = Int(round(size(best_calibrations)[1]/4))
        # parameters_best_calibrations = best_calibrations[1+((ID-1) * index):ID*index,10:29]

        for n in 1 : nmax#1:size(parameters_best_calibrations)[1]
                #print(n,"\n")
                Current_Inputs_All_Zones = deepcopy(Inputs_All_Zones)
                Current_Storages_All_Zones = deepcopy(Storages_All_Zones)
                Current_GWStorage = deepcopy(GWStorage)
                parameters, slow_parameters, parameters_array = parameter_selection_feistritz_srdef(min_srdef_Grass, min_srdef_Forest, min_srdef_Bare, min_srdef_Rip, max_srdef_Grass, max_srdef_Forest, max_srdef_Bare, max_srdef_Rip)


                # beta_Bare, beta_Forest, beta_Grass, beta_Rip, Ce, Interceptioncapacity_Forest, Interceptioncapacity_Grass, Interceptioncapacity_Rip, Kf_Rip, Kf, Ks, Meltfactor, Mm, Ratio_Pref, Ratio_Riparian, Soilstoaragecapacity_Bare, Soilstoaragecapacity_Forest, Soilstoaragecapacity_Grass, Soilstoaragecapacity_Rip, Temp_Thresh = parameters_best_calibrations[n, :]
                # bare_parameters = Parameters(beta_Bare, Ce, 0, 0.0, Kf, Meltfactor, Mm, Ratio_Pref, Soilstoaragecapacity_Bare, Temp_Thresh)
                # forest_parameters = Parameters(beta_Forest, Ce, 0, Interceptioncapacity_Forest, Kf, Meltfactor, Mm, Ratio_Pref, Soilstoaragecapacity_Forest, Temp_Thresh)
                # grass_parameters = Parameters(beta_Grass, Ce, 0, Interceptioncapacity_Grass, Kf, Meltfactor, Mm, Ratio_Pref, Soilstoaragecapacity_Grass, Temp_Thresh)
                # rip_parameters = Parameters(beta_Rip, Ce, 0.0, Interceptioncapacity_Rip, Kf, Meltfactor, Mm, Ratio_Pref, Soilstoaragecapacity_Rip, Temp_Thresh)
                # slow_parameters = Slow_Paramters(Ks, Ratio_Riparian)
                #
                # parameters = [bare_parameters, forest_parameters, grass_parameters, rip_parameters]
                # parameters_array = parameters_best_calibrations[n, :]
                #parameters, slow_parameters, parameters_array = parameter_selection_feistritz()

                # parameter ranges
                #parameters, parameters_array = parameter_selection()
                Discharge, Snow_Extend = runmodelprecipitationzones(Potential_Evaporation, Precipitation_All_Zones, Temperature_Elevation_Catchment, Current_Inputs_All_Zones, Current_Storages_All_Zones, Current_GWStorage, parameters, slow_parameters, Area_Zones, Area_Zones_Percent, Elevation_Percentage, Elevation_Zone_Catchment, ID_Prec_Zones, Nr_Elevationbands_All_Zones, observed_snow_cover, start2000)
                #calculate snow for each precipitation zone
                Discharge = Discharge * 1000 / Area_Catchment * (3600 * 24)
                # don't calculate the goodness of fit for the spinup time!
                Discharge_Obj = Discharge[index_spinup:index_lastdate]
                deleteat!(Discharge_Obj, delete_days)
                Goodness_Fit, ObjFunctions = objectivefunctions_delete_days(Discharge[index_spinup:index_lastdate], Discharge_Obj, Snow_Extend, Observed_Discharge_Obj, observed_FDC, observed_AC_1day, observed_AC_90day, observed_monthly_runoff, Area_Catchment, Total_Precipitation_Obj, Timeseries_Obj)
                #if goodness higher than -9999 save it
                if Goodness_Fit != -9999
                        Goodness = [Goodness_Fit, ObjFunctions, parameters_array]
                        Goodness = collect(Iterators.flatten(Goodness))
                        All_Goodness = hcat(All_Goodness, Goodness)
                        if size(All_Goodness)[2]-1 == 100
                                All_Goodness = transpose(All_Goodness[:, 2:end])
                                if count != 100
                                        open(local_path*"Calibrations_Srdef/Feistritz/Feistritz_Parameterfit_srdef_test"*string(ID)*"_"*string(number_Files)*".csv", "a") do io
                                                writedlm(io, All_Goodness,",")
                                        end
                                        count+= 1
                                else
                                        open(local_path*"Calibrations_Srdef/Feistritz/Feistritz_Parameterfit_srdef_test"*string(ID)*"_"*string(number_Files)*".csv", "a") do io
                                                writedlm(io, All_Goodness,",")
                                        end
                                        count = 1
                                        number_Files += 1
                                end

                                #print("worker ", ID, " wrote 100 tested parameter sets to file.", "\n")
                                All_Goodness = zeros(29)
                        end
                end
                if mod(n, 1000) == 0
                        print("number of runs", n, "\n")
                end
        end
        All_Goodness = transpose(All_Goodness[:, 2:end])
        open(local_path*"Calibrations_Srdef/Feistritz/Feistritz_Parameterfit_srdef_"*ep_method*"_"*timeframes*"_"*string(ID)*".csv", "a") do io
                writedlm(io, All_Goodness,",")
        end
end
#
# nmax = 300
# @time begin
# #run_MC(1,700)
# pmap(ID -> run_MC(ID, nmax) , [1,2,3,4,5,6,7])
# end

function run_MC_time_ep(nmax)
        local_path = "/Users/magali/Documents/1. Master/1.4 Thesis/02 Execution/01 Model Sarah/"

        Area_Zones = [115496400.]
        Area_Catchment = sum(Area_Zones)
        Percentage_HRU = CSV.read(local_path*"HBVModel/Feistritz/HRU_Prec_Zones.csv", DataFrame, header=[1], decimal='.', delim = ',')

        Area_f = (sum(Percentage_HRU[2,2:end])/Area_Catchment)
        Area_g = (sum(Percentage_HRU[3,2:end])/Area_Catchment)
        Area_r = (sum(Percentage_HRU[4,2:end])/Area_Catchment)
        Area_b = (sum(Percentage_HRU[1,2:end])/Area_Catchment)

        PEmethod = ["TW", "HG"]
        Timeframes = ["OP", "MP", "MF"]
        parameter_range = CSV.read("/Users/magali/Documents/1. Master/1.4 Thesis/02 Execution/01 Model Sarah/Results/Rootzone/Srdef_ranges/rcp45/CNRM-CERFACS-CNRM-CM5_rcp45_r1i1p1_CLMcom-CCLM4-8-17_v1_day/Feistritz_srdef_range.csv", DataFrame, decimal = '.', delim = ',' )

        for (e, ep_method) in enumerate(PEmethod)
                for (t,timeframes) in enumerate(Timeframes)
                        println("current loop: ", ep_method, " ", timeframes)
                        min_srdef_Grass = parameter_range[t,2*e] * Area_g
                        min_srdef_Rip = parameter_range[t,2*e] * Area_r
                        min_srdef_Bare = 0.0
                        min_srdef_Forest = parameter_range[t+3,2*e] * Area_f
                        max_srdef_Grass = parameter_range[t,2*e+1]* Area_g
                        max_srdef_Rip = parameter_range[t,2*e+1] * Area_r
                        max_srdef_Bare = 50.0 * Area_b
                        max_srdef_Forest = parameter_range[t+3,2*e+1] * Area_f
                        @time begin
                        #run_MC(1,100)
                        pmap(ID -> run_MC(ID, nmax, min_srdef_Grass, min_srdef_Forest, min_srdef_Bare, min_srdef_Rip, max_srdef_Grass, max_srdef_Forest, max_srdef_Bare, max_srdef_Rip, ep_method, timeframes) , [1])
                        end
                end
        end
end

run_MC_time_ep(300)
