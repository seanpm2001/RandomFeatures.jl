using Test
using Distributions
using StableRNGs
using StatsBase
using LinearAlgebra
using Random


using RandomFeatures.Utilities
using RandomFeatures.Samplers
using RandomFeatures.Features
using RandomFeatures.Methods
using RandomFeatures.DataContainers
using RandomFeatures.ParameterDistributions


seed = 2023

@testset "Methods" begin

    @testset "construction of RFM" begin
        rng = StableRNG(seed)

        #specify features
        μ_c = 0.0
        σ_c = 2.0
        pd = constrained_gaussian("xi", μ_c, σ_c, -Inf, Inf)
        feature_sampler = FeatureSampler(pd, rng = copy(rng))

        n_features = 100
        sigma_fixed = Dict("sigma" => 10.0)

        sff = ScalarFourierFeature(n_features, feature_sampler, feature_parameters = sigma_fixed)

        # configure the method, and fit 
        batch_sizes_err = Dict("train" => 100, "test" => 100, "NOT_FEATURES" => 100)
        batch_sizes = Dict("train" => 100, "test" => 100, "feature" => 100)
        lambda_warn = -1
        lambda = 1e-4

        @test_throws ArgumentError RandomFeatureMethod(sff, regularization = lambda, batch_sizes = batch_sizes_err)

        rfm_warn = RandomFeatureMethod(sff, regularization = lambda_warn, batch_sizes = batch_sizes)
        @test get_regularization(rfm_warn) ≈ 1e12 * eps()

        rfm = RandomFeatureMethod(sff, regularization = lambda, batch_sizes = batch_sizes)

        @test get_batch_sizes(rfm) == batch_sizes
        rf_test = get_random_feature(rfm)
        #too arduous right now to check rf_test == sff will wait until "==" is overloaded for ParameterDistribution

        rfm_default = RandomFeatureMethod(sff)

        @test get_batch_sizes(rfm_default) == Dict("train" => 0, "test" => 0, "feature" => 0)
        @test get_regularization(rfm_default) ≈ 1e12 * eps()
    end

    @testset "Fit and predict: 1D -> 1D" begin
        rng_base = StableRNG(seed)

        # looks like a 4th order polynomial near 0, then is damped to 0 toward +/- inf
        ftest(x::AbstractVecOrMat) = exp.(-0.5 * x .^ 2) .* (x .^ 4 - x .^ 3 - x .^ 2 + x .- 1)

        exp_range = [1, 2, 4]
        n_data_exp = 20 * exp_range


        priorL2err = zeros(length(exp_range), 3)
        priorweightedL2err = zeros(length(exp_range), 3)
        L2err = zeros(length(exp_range), 3)
        weightedL2err = zeros(length(exp_range), 3)

        # values with 1/var learning in examples/Learn_hyperparameters/1d_to_1d_regression_direct_withcov.jl

        σ_c_vec = [2.5903560156755194, 1.9826946095752571, 2.095420236641444]
        σ_c_snf_vec = [9.606414682837055, 4.406586351058134, 2.756419855446525]
        σ_c_ssf_vec = [2.2041952067873742, 3.0205667976224384, 4.307656997874708]

        for (exp_idx, n_data, σ_c, σ_c_snf, σ_c_ssf) in
            zip(1:length(exp_range), n_data_exp, σ_c_vec, σ_c_snf_vec, σ_c_ssf_vec)

            rng = copy(rng_base)
            #problem formulation
            x = rand(rng, Uniform(-3, 3), n_data)
            noise_sd = 0.1
            noise = rand(rng, Normal(0, noise_sd), n_data)

            y = ftest(x) + noise
            io_pairs = PairedDataContainer(reshape(x, 1, :), reshape(y, 1, :), data_are_columns = true) #matrix input

            xtestvec = collect(-3:0.01:3)
            ntest = length(xtestvec) #extended domain
            xtest = DataContainer(reshape(xtestvec, 1, :), data_are_columns = true)
            ytest_nonoise = ftest(get_data(xtest))

            # specify feature distributions
            # NB we optimize hyperparameter values σ_c in examples/Learn_hyperparameters/1d_to_1d_regression.jl
            # Such values may change with different ftest and different noise_sd

            n_features = 400

            μ_c = 0.0
            pd = constrained_gaussian("xi", μ_c, σ_c, -Inf, Inf)
            feature_sampler = FeatureSampler(pd, rng = copy(rng))
            sff = ScalarFourierFeature(n_features, feature_sampler)

            pd_snf = constrained_gaussian("xi", μ_c, σ_c_snf, -Inf, Inf)
            feature_sampler_snf = FeatureSampler(pd_snf, rng = copy(rng))
            snf = ScalarNeuronFeature(n_features, feature_sampler_snf)

            pd_ssf = constrained_gaussian("xi", μ_c, σ_c_ssf, -Inf, Inf)
            feature_sampler_ssf = FeatureSampler(pd_ssf, rng = copy(rng))
            ssf = ScalarFeature(n_features, feature_sampler_ssf, Sigmoid())
            #first case without batches
            lambda = noise_sd^2
            rfm = RandomFeatureMethod(sff, regularization = lambda)

            fitted_features = fit(rfm, io_pairs)
            decomp = get_feature_factors(fitted_features)
            @test typeof(decomp) == Decomposition{Factor}
            @test typeof(get_decomposition(decomp)) <: SVD

            coeffs = get_coeffs(fitted_features)

            #second case with batching
            batch_sizes = Dict("train" => 100, "test" => 100, "feature" => 100)

            rfm_batch = RandomFeatureMethod(sff, batch_sizes = batch_sizes, regularization = lambda)

            fitted_batched_features = fit(rfm_batch, io_pairs)
            coeffs_batched = get_coeffs(fitted_batched_features)
            @test coeffs ≈ coeffs_batched

            # test prediction with different features
            pred_mean, pred_cov = predict(rfm_batch, fitted_batched_features, xtest)

            rfm_relu = RandomFeatureMethod(snf, batch_sizes = batch_sizes, regularization = lambda)
            fitted_relu_features = fit(rfm_relu, io_pairs)
            pred_mean_relu, pred_cov_relu = predict(rfm_relu, fitted_relu_features, xtest)

            rfm_sig = RandomFeatureMethod(ssf, batch_sizes = batch_sizes, regularization = lambda)
            fitted_sig_features = fit(rfm_sig, io_pairs)
            pred_mean_sig, pred_cov_sig = predict(rfm_sig, fitted_sig_features, xtest)

            prior_mean, prior_cov = predict_prior(rfm_batch, xtest) # predict inputs from unfitted features
            prior_mean_relu, prior_cov_relu = predict_prior(rfm_relu, xtest)
            prior_mean_sig, prior_cov_sig = predict_prior(rfm_sig, xtest)

            # enforce positivity
            prior_cov = max.(0, prior_cov)
            prior_cov_relu = max.(0, prior_cov_relu)
            prior_cov_sig = max.(0, prior_cov_sig)
            pred_cov = max.(0, pred_cov)
            pred_cov_relu = max.(0, pred_cov_relu)
            pred_cov_sig = max.(0, pred_cov_sig)
            # added Plots for these different predictions:
            if TEST_PLOT_FLAG

                clrs = map(x -> get(colorschemes[:hawaii], x), [0.25, 0.5, 0.75])
                plt = plot(
                    get_data(xtest)',
                    ytest_nonoise',
                    show = false,
                    color = "black",
                    linewidth = 5,
                    size = (600, 600),
                    legend = :topleft,
                    label = "Target",
                )

                plot!(
                    get_data(xtest)',
                    pred_mean',
                    ribbon = [2 * sqrt.(pred_cov[1, 1, :]); 2 * sqrt.(pred_cov[1, 1, :])]',
                    label = "Fourier",
                    color = clrs[1],
                )

                plot!(
                    get_data(xtest)',
                    pred_mean_relu',
                    ribbon = [2 * sqrt.(pred_cov_relu[1, 1, :]); 2 * sqrt.(pred_cov_relu[1, 1, :])]',
                    label = "Relu",
                    color = clrs[2],
                )

                plot!(
                    get_data(xtest)',
                    pred_mean_sig',
                    ribbon = [2 * sqrt.(pred_cov_sig[1, 1, :]); 2 * sqrt.(pred_cov_sig[1, 1, :])]',
                    label = "Sigmoid",
                    color = clrs[3],
                )

                scatter!(x, y, markershape = :x, label = "", color = "black", markersize = 6)
                savefig(plt, joinpath(@__DIR__, "Fit_and_predict_1D_" * string(exp_range[exp_idx]) * ".pdf"))
            end
            priorL2err[exp_idx, :] += [
                sqrt(sum((ytest_nonoise - prior_mean) .^ 2)),
                sqrt(sum((ytest_nonoise - prior_mean_relu) .^ 2)),
                sqrt(sum((ytest_nonoise - prior_mean_sig) .^ 2)),
            ]
            priorweightedL2err[exp_idx, :] += [
                sqrt(sum(1 ./ prior_cov .* (ytest_nonoise - prior_mean) .^ 2)),
                sqrt(sum(1 ./ prior_cov_relu .* (ytest_nonoise - prior_mean_relu) .^ 2)),
                sqrt(sum(1 ./ prior_cov_sig .* (ytest_nonoise - prior_mean_sig) .^ 2)),
            ]
            L2err[exp_idx, :] += [
                sqrt(sum((ytest_nonoise - pred_mean) .^ 2)),
                sqrt(sum((ytest_nonoise - pred_mean_relu) .^ 2)),
                sqrt(sum((ytest_nonoise - pred_mean_sig) .^ 2)),
            ]
            weightedL2err[exp_idx, :] += [
                sqrt(sum(1 ./ pred_cov .* (ytest_nonoise - pred_mean) .^ 2)),
                sqrt(sum(1 ./ pred_cov_relu .* (ytest_nonoise - pred_mean_relu) .^ 2)),
                sqrt(sum(1 ./ pred_cov_sig .* (ytest_nonoise - pred_mean_sig) .^ 2)),
            ]
        end

        println("Prior for 1d->1d:")
        println("L2 errors: fourier, neuron, sigmoid")
        println(priorL2err)
        # println("weighted L2 errors: fourier, neuron, sigmoid")
        # println(priorweightedL2err)

        println("Posterior for 1d->1d, with increasing data:")
        println("L2 errors: fourier, neuron, sigmoid")
        println(L2err)
        @test all([all(L2err[i, :] .< L2err[i - 1, :]) for i in 2:size(L2err, 1)])
        ## This test is too brittle for small data
        # println("weighted L2 errors: fourier, neuron, sigmoid")
        # println(weightedL2err)
        # @test all([all(weightedL2err[i,:] .< weightedL2err[i-1,:]) for i=2:size(weightedL2err,1)])

    end # testset "Fit and predict"


    @testset "Fit and predict: N-D -> 1-D" begin

        rng = StableRNG(seed + 1)
        input_dim = 6
        n_features = 4000
        ftest_nd_to_1d(x::AbstractMatrix) =
            mapslices(column -> exp(-0.1 * norm([i * c for (i, c) in enumerate(column)])^2), x, dims = 1)

        #problem formulation
        n_data = 2000
        x = rand(rng, MvNormal(zeros(input_dim), I), n_data)
        noise_sd = 1e-6
        lambda = noise_sd^2
        noise = rand(rng, Normal(0, noise_sd), (1, n_data))

        y = ftest_nd_to_1d(x) + noise
        io_pairs = PairedDataContainer(x, y)

        n_test = 1000
        xtestvec = rand(rng, MvNormal(zeros(input_dim), I), n_test)

        xtest = DataContainer(xtestvec)
        ytest_nonoise = ftest_nd_to_1d(get_data(xtest))

        # specify features
        # note the σ_c and sigma values come from `examples/Learn_hyperparameters/nd_to_1d_regression_direct_matchingcov.jl`
        μ_c = 0.0
        σ_c = [
            0.4234088946781989,
            0.8049531151024479,
            2.0175064410998393,
            1.943714718437188,
            2.9903379860220314,
            3.3332086723624266,
        ]
        pd = ParameterDistribution(
            Dict(
                "distribution" => VectorOfParameterized(map(sd -> Normal(μ_c, sd), σ_c)),
                "constraint" => repeat([no_constraint()], input_dim),
                "name" => "xi",
            ),
        )
        feature_sampler = FeatureSampler(pd, rng = copy(rng))
        sff = ScalarFourierFeature(n_features, feature_sampler)

        #second case with batching
        batch_sizes = Dict("train" => 500, "test" => 500, "feature" => 500)

        rfm_batch = RandomFeatureMethod(sff, batch_sizes = batch_sizes, regularization = lambda)

        fitted_batched_features = fit(rfm_batch, io_pairs)

        # test prediction with different features
        prior_mean, prior_cov = predict_prior(rfm_batch, xtest) # predict inputs from unfitted features
        priorL2err = sqrt(sum((ytest_nonoise - prior_mean) .^ 2))
        priorweightedL2err = sqrt(sum(1 ./ prior_cov .* (ytest_nonoise - prior_mean) .^ 2))
        println("Prior for nd->1d")
        println("L2 error: ", priorL2err)
        println("weighted L2 error: ", priorweightedL2err)

        pred_mean, pred_cov = predict(rfm_batch, fitted_batched_features, xtest)
        L2err = sqrt(sum((ytest_nonoise - pred_mean) .^ 2))
        weightedL2err = sqrt(sum(1 ./ pred_cov .* (ytest_nonoise - pred_mean) .^ 2))
        println("Posterior for nd->1d")
        println("L2 error: ", L2err)
        println("weighted L2 error: ", weightedL2err)

        @test L2err < priorL2err
        @test weightedL2err < priorweightedL2err

        if TEST_PLOT_FLAG
            #plot slice through one dimensions, others fixed to 0
            xrange = collect(-3:0.01:3)
            xslice = zeros(input_dim, length(xrange))
            for direction in 1:input_dim
                xslicenew = copy(xslice)
                xslicenew[direction, :] = xrange

                yslice = ftest_nd_to_1d(xslicenew)

                pred_mean_slice, pred_cov_slice = predict(rfm_batch, fitted_batched_features, DataContainer(xslicenew))
                pred_cov_slice[1, 1, :] = max.(pred_cov_slice[1, 1, :], 0.0)
                plt = plot(
                    xrange,
                    yslice',
                    show = false,
                    color = "black",
                    linewidth = 5,
                    size = (600, 600),
                    legend = :topleft,
                    label = "Target",
                )
                plot!(
                    xrange,
                    pred_mean_slice',
                    ribbon = [2 * sqrt.(pred_cov_slice[1, 1, :]); 2 * sqrt.(pred_cov_slice[1, 1, :])]',
                    label = "Fourier",
                    color = "blue",
                )
                savefig(
                    plt,
                    joinpath(@__DIR__, "Fit_and_predict_ND_" * string(direction) * "of" * string(input_dim) * ".pdf"),
                )
            end
        end
    end

    @testset "Fit and predict: 1-D -> M-D" begin
        rng = StableRNG(seed + 2)
        input_dim = 1
        output_dim = 2
        n_features = 100
        function ftest_1d_to_2d(x::AbstractMatrix)
            out = zeros(2, size(x, 2))
            out[1, :] = mapslices(column -> sin(norm([i * c for (i, c) in enumerate(column)])^2), x, dims = 1)
            out[2, :] = mapslices(column -> exp(-0.1 * norm([i * c for (i, c) in enumerate(column)])^2), x, dims = 1)
            return out
        end

        #problem formulation
        n_data = 50
        x = rand(rng, MvNormal(zeros(input_dim), I), n_data)
        noise_sd = 1e-1
        lambda = noise_sd^2
        noise = rand(rng, Normal(0, noise_sd), (output_dim, n_data))

        y = ftest_1d_to_2d(x) + noise
        io_pairs = PairedDataContainer(x, y)

        n_test = 200
        xtestvec = rand(rng, MvNormal(zeros(input_dim), I), n_test)

        xtest = DataContainer(xtestvec)
        ytest_nonoise = ftest_1d_to_2d(get_data(xtest))

        # numbers from examples/hyperparameter_learning/nd_to_md_regression_direct_withcov.jl
        M = zeros(input_dim, output_dim)
        U = Diagonal([0.9634446604994962])
        V = Diagonal([4.681506805674389, 1.7898435955588452])


        dist = MatrixNormal(M, U, V) #produces matrix samples
        pd = ParameterDistribution(
            Dict(
                "distribution" => Parameterized(dist),
                "constraint" => repeat([no_constraint()], input_dim * output_dim),
                "name" => "xi",
            ),
        )
        feature_sampler = FeatureSampler(pd, output_dim, rng = copy(rng))
        vff = VectorFourierFeature(n_features, output_dim, feature_sampler)

        batch_sizes = Dict("train" => 500, "test" => 500, "feature" => 500)
        rfm_batch = RandomFeatureMethod(vff, batch_sizes = batch_sizes, regularization = lambda)
        fitted_batched_features = fit(rfm_batch, io_pairs)

        # test prediction L^2 error of mean
        prior_mean, prior_cov = predict_prior(rfm_batch, xtest) # predict inputs from unfitted features
        #  2 x n,  2 x 2 x n
        priorL2err = sqrt.(sum((ytest_nonoise - prior_mean) .^ 2))
        priorweightedL2err = [0.0]
        for i in 1:n_test
            diff = reshape(ytest_nonoise[:, i] - prior_mean[:, i], :, 1)
            priorweightedL2err .+= sum(permutedims(diff, (2, 1)) * inv(prior_cov[:, :, i]) * diff)
        end
        priorweightedL2err = sqrt.(priorweightedL2err)[:]
        println("Prior for 1d->2d")
        println("L2 error: ", priorL2err)
        #        println("weighted L2 error: ", priorweightedL2err)

        pred_mean, pred_cov = predict(rfm_batch, fitted_batched_features, xtest)
        L2err = sqrt.(sum((ytest_nonoise - pred_mean) .^ 2))
        weightedL2err = [0.0]
        for i in 1:n_test
            diff = reshape(ytest_nonoise[:, i] - pred_mean[:, i], :, 1)
            weightedL2err .+= sum(permutedims(diff, (2, 1)) * inv(pred_cov[:, :, i]) * diff)
        end
        weightedL2err = sqrt.(weightedL2err)[:]
        println("Posterior for 1d->2d")
        println("L2 error: ", L2err)
        #        println("weighted L2 error: ", weightedL2err)

        @test L2err < priorL2err
        #        @test weightedL2err < priorweightedL2err


        if TEST_PLOT_FLAG
            # learning on Normal(0,1) dist, forecast on (-2,2)
            xrange = reshape(collect(-2:0.02:2), 1, :)

            yrange = ftest_1d_to_2d(xrange)

            pred_mean_slice, pred_cov_slice = predict(rfm_batch, fitted_batched_features, DataContainer(xrange))

            pred_cov_slice[1, 1, :] = max.(pred_cov_slice[1, 1, :], 0.0)
            pred_cov_slice[2, 2, :] = max.(pred_cov_slice[2, 2, :], 0.0)

            #plot diagonal
            xplot = xrange[:]
            plt = plot(
                xplot,
                yrange[1, :],
                show = false,
                color = "black",
                linewidth = 5,
                size = (600, 600),
                legend = :topleft,
                label = "Target",
            )
            plot!(
                xplot,
                yrange[2, :],
                show = false,
                color = "black",
                linewidth = 5,
                size = (600, 600),
                legend = :topleft,
                label = "Target",
            )
            println(y[1, :])
            scatter!(x[:], y[1, :], color = "blue", label = "", marker = :x)

            plot!(
                xplot,
                pred_mean_slice[1, :],
                ribbon = [2 * sqrt.(pred_cov_slice[1, 1, :]); 2 * sqrt.(pred_cov_slice[1, 1, :])],
                label = "Fourier",
                color = "blue",
            )
            scatter!(x[:], y[2, :], color = "red", label = "", marker = :x)
            plot!(
                xplot,
                pred_mean_slice[2, :],
                ribbon = [2 * sqrt.(pred_cov_slice[2, 2, :]); 2 * sqrt.(pred_cov_slice[2, 2, :])],
                label = "Fourier",
                color = "red",
            )

            savefig(plt, joinpath(@__DIR__, "Fit_and_predict_1D_to_2D.pdf"))
        end
    end

end
