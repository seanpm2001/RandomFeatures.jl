using Test
using StableRNGs
using StatsBase
using LinearAlgebra
using Random
using Distributions
using EnsembleKalmanProcesses.ParameterDistributions

using RandomFeatures.Samplers
using RandomFeatures.Features

seed = 2202

@testset "Features" begin
   @testset "ScalarFunctions" begin

       af_list = [
           Relu(),
           Lrelu(),
           Gelu(),
           Elu(),
           Selu(),
           Heaviside(),
           SmoothHeaviside(),
           Sawtooth(),
           Softplus(),
           Tansig(),
           Sigmoid(),
       ]
       # very rough tests that these are activation functions
       for af in af_list
           @test isa(af,ScalarActivation)

           x_test_neg = collect(-1:0.1:-0.1)
           x_test_pos = collect(0:0.1:1)
           println("Testing ", af)
           @test all(apply_scalar_function(af, x_test_neg) .<= log(2)) # small for negative x
           
           if !isa(af,Sawtooth)
               @test all(apply_scalar_function(af, x_test_pos[2:end]) - apply_scalar_function(af, x_test_pos[1:end-1]) .>= 0) # monotone increasing for positive x
           else
               x_test_0_0pt5 = collect(0:0.1:0.5)
               x_test_0pt5_1 = collect(0.5:0.1:1)
               @test all(apply_scalar_function(af, x_test_0_0pt5[2:end]) - apply_scalar_function(af, x_test_0_0pt5[1:end-1]) .>= 0) 
               @test all(apply_scalar_function(af, x_test_0pt5_1[2:end]) - apply_scalar_function(af, x_test_0pt5_1[1:end-1]) .<= 0) 
           end
       end

       # others
       sf = Features.Cosine() # as Distributions also has a Cosine()
       println("Testing ", sf)
       @test isa(sf,ScalarFunction)
       
       x_test = collect(-1:0.1:1)
       @test all(abs.(apply_scalar_function(sf,x_test) - cos.(x_test)) .< 2*eps())
       
    end

    @testset "Constructors" begin

        n_features = 20
        relu=Relu()
        rng = StableRNG(seed)
        
        #setup sampler xi distributions
        μ_c = 0.0
        σ_c = 2.0
        pd_err = constrained_gaussian("test", μ_c, σ_c, -Inf, Inf)
        feature_sampler_err = Sampler(pd_err, rng=copy(rng))
        pd = constrained_gaussian("xi", μ_c, σ_c, -Inf, Inf)
        feature_sampler = Sampler(pd, rng=copy(rng))

        # postive constraints for sigma
        hyper_μ_c = 10.0
        hyper_σ_c = 1.0
        sigma_pd_err = constrained_gaussian("not sigma", hyper_μ_c, hyper_σ_c, 0.0, Inf)
        sigma_sampler_err = Sampler(sigma_pd_err, rng=copy(rng))
        sigma_pd = constrained_gaussian("sigma", hyper_μ_c, hyper_σ_c, 0.0, Inf)
        sigma_sampler = Sampler(sigma_pd, rng=copy(rng),uniform_shift_bounds=nothing)

        sigma_fixed_err = Dict("not sigma" => 10.0)
        sigma_fixed = Dict("sigma" => 10.0)

        
        
        # Error checks
        @test_throws ArgumentError ScalarFeature(
            n_features,
            feature_sampler_err, # causes error
            relu,
            hyper_fixed=sigma_fixed
        )
        @test_throws ArgumentError ScalarFeature(
            n_features,
            feature_sampler,
            relu, #neither hyper_sampler nor hyper_fixed defined
        )
        @test_throws ArgumentError ScalarFeature(
            n_features,
            feature_sampler,
            relu,
            hyper_sampler = sigma_sampler_err, # causes error
        )
        @test_throws ArgumentError ScalarFeature(
            n_features,
            feature_sampler,
            relu,
            hyper_fixed = sigma_fixed_err, # causes error
        )
        @test_logs (:info,"both a `hyper_fixed=` and `hyper_sampler=` specify \"sigma\","*"\n defaulting to optimize \"sigma\" with hyper_sampler") ScalarFeature(
            n_features,
            feature_sampler,
            relu,
            hyper_sampler = sigma_sampler,
            hyper_fixed = sigma_fixed, 
        )
        sf_test = ScalarFeature(
            n_features,
            feature_sampler,
            relu,
            hyper_sampler = sigma_sampler,
            hyper_fixed = sigma_fixed, 
        )
        
        @test get_hyper_fixed(sf_test) == nothing # gets set to nothing when two are defined       
        
        # ScalarFeature and getters
        feature_sampler = Sampler(pd, rng=copy(rng)) # to reset the rng
        sf_test = ScalarFeature(
            n_features,
            feature_sampler,
            relu,
            hyper_sampler = sigma_sampler,
        )
        @test get_n_features(sf_test) == n_features

        test_sample = sample(copy(rng), feature_sampler, n_features)
        sf_test_sample = get_feature_sample(sf_test)
        # cumbersome as distributions can't equate each other with "==" (Issue in EnsembleKalmanProcesses)
        @test get_distribution(sf_test_sample)["xi"] == get_distribution(test_sample)["xi"]
        @test get_distribution(sf_test_sample)["uniform"] == get_distribution(test_sample)["uniform"]
        @test get_all_constraints(sf_test_sample) == get_all_constraints(test_sample)
        @test get_name(sf_test_sample) == get_name(test_sample)
        sf_test_sampler = get_feature_sampler(sf_test)
        @test get_uniform_shift_bounds(sf_test_sampler) == [0,2*pi]
        @test get_optimizable_parameters(sf_test_sampler) == nothing
        
        sff_test = ScalarFourierFeature(
            n_features,
            feature_sampler,
            hyper_sampler = sigma_sampler,
        )
       
        snf_test = ScalarNeuronFeature(
            n_features,
            feature_sampler,
            hyper_sampler = sigma_sampler,
        )

        @test isa(get_scalar_function(sff_test), Features.Cosine)
        @test isa(get_scalar_function(snf_test), Relu)
        
    end

    @testset "build features" begin

        n_features = 20
        rng = StableRNG(seed)
        
        μ_c = 0.0
        σ_c = 2.0
        pd = constrained_gaussian("xi", μ_c, σ_c, -Inf, Inf)
        feature_sampler = Sampler(pd, rng=copy(rng))

        sigma_value = 10.0
        sigma_fixed = Dict("sigma" => sigma_value)

        sff_test = ScalarFourierFeature(
            n_features,
            feature_sampler,
            hyper_fixed = sigma_fixed,
        )

        # 1D input space
        inputs_1d = reshape(collect(-1:0.01:1),(201,1))
        features = build_features(sff_test,inputs_1d)

        rng1 = copy(rng)
        samp_xi = reshape(sample(rng1, pd, n_features), (1, n_features))
        samp_unif = reshape(rand(rng1, Uniform(0,2*pi), n_features), (1, n_features))
        
        rf_test = sqrt(2) * sigma_value * cos.(inputs_1d * samp_xi .+ samp_unif)
        @test all(abs.(rf_test - features) .< 10*eps()) # sufficiently big to deal with inaccuracy of cosine
    end

end
