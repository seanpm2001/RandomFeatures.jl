module Samplers

import StatsBase: sample

using Random, Distributions, DocStringExtensions, EnsembleKalmanProcesses.ParameterDistributions

export Sampler, FeatureSampler, get_parameter_distribution, get_rng, sample

"""
$(TYPEDEF)

Wraps the parameter distributions used to sample random features

$(TYPEDFIELDS)
"""
struct Sampler
    "A probability distribution, possibly with constraints"
    parameter_distribution::ParameterDistribution
    "A random number generator state"
    rng::AbstractRNG
end

"""
$(TYPEDSIGNATURES)

basic constructor for a `Sampler` 
"""
function FeatureSampler(
    parameter_distribution::ParameterDistribution,
    bias_distribution::Union{ParameterDistribution, Nothing};
    rng::AbstractRNG = Random.GLOBAL_RNG,
)
    if isnothing(bias_distribution) # no bias
        return Sampler(parameter_distribution, rng)
    else
        pd = combine_distributions([parameter_distribution, bias_distribution])
        return Sampler(pd, rng)
    end
end

"""
$(TYPEDSIGNATURES)

one can conveniently specify the bias as a uniform-shift `uniform_shift_bounds` with `output_dim` dimensions
"""
function FeatureSampler(
    parameter_distribution::ParameterDistribution,
    output_dim::Int;
    uniform_shift_bounds::AbstractVector = [0, 2 * pi],
    rng::AbstractRNG = Random.GLOBAL_RNG,
)

    # adds a uniform distribution to the parameter distribution
    if output_dim == 1
        unif_dict = Dict(
            "distribution" => Parameterized(Uniform(uniform_shift_bounds[1], uniform_shift_bounds[2])),
            "constraint" => no_constraint(),
            "name" => "bias",
        )
    else
        unif_dict = Dict(
            "distribution" => VectorOfParameterized(
                repeat([Uniform(uniform_shift_bounds[1], uniform_shift_bounds[2])], output_dim),
            ),
            "constraint" => repeat([no_constraint()], output_dim),
            "name" => "bias",
        )
    end
    unif_pd = ParameterDistribution(unif_dict)

    pd = combine_distributions([parameter_distribution, unif_pd])
    return Sampler(pd, rng)
end

FeatureSampler(parameter_distribution::ParameterDistribution; kwargs...) =
    FeatureSampler(parameter_distribution, 1; kwargs...)

"""
$(TYPEDSIGNATURES)

gets the `parameter_distribution` field 
"""
get_parameter_distribution(s::Sampler) = s.parameter_distribution

"""
$(TYPEDSIGNATURES)

gets the `rng` field
"""
get_rng(s::Sampler) = s.rng

"""
$(TYPEDSIGNATURES)

samples the distribution within `s`, `n_draws` times using a random number generator `rng`. Can be called without `rng` (defaults to `s.rng`) or `n_draws` (defaults to `1`)
"""
function sample(rng::AbstractRNG, s::Sampler, n_draws::Int)
    pd = get_parameter_distribution(s)
    # TODO: Support for Matrix Distributions, Flattening them for now.
    # until EKP.ParameterDistributions we sample Julia distributions directly
    if any([length(size(get_distribution(d))) > 1 for d in pd.distribution])
        # get [ [in x out] x samples, [out x samples]]
        samps = [sample(rng, d, n_draws) for d in pd.distribution]
        samp_xi = cat(samps[1]..., dims = 3) # [in x out x samples]
        samp_xi = reshape(samp_xi, size(samp_xi, 1) * size(samp_xi, 2), size(samp_xi, 3)) # stacks in+in+... to make a  (in x out) x samples
        samp_bias = samps[2] # out x samples 
        samp = cat(samp_xi, samp_bias, dims = 1) # (in x out + out) x 20
    else
        samp = cat([sample(rng, d, n_draws) for d in pd.distribution]..., dims = 1)
    end
    #samp = sample(rng, pd, n_draws) # vec(univariate), mat(multivariate) or vec of mats (matrixvariate)
    constrained_samp = transform_unconstrained_to_constrained(pd, samp)
    #now create a Samples-type distribution from the samples
    s_names = get_name(pd)
    s_slices = batch(pd) # e.g.,"xi","bias" [1:3,4:6]
    s_samples = [Samples(constrained_samp[slice, :]) for slice in s_slices]
    s_constraints = [repeat([no_constraint()], size(slice, 1)) for slice in s_slices]

    return combine_distributions([
        ParameterDistribution(ss, sc, sn) for (ss, sc, sn) in zip(s_samples, s_constraints, s_names)
    ])
end

sample(s::Sampler, n_draws::Int) = sample(s.rng, s, n_draws)
sample(rng::AbstractRNG, s::Sampler) = sample(rng, s, 1)
sample(s::Sampler) = sample(s.rng, s, 1)



end # module
