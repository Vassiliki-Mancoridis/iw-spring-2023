using DiffEqFlux, OrdinaryDiffEq, Flux, Optim, Plots
using DifferentialEquations
using DiffEqSensitivity
using Zygote
using ForwardDiff
using LinearAlgebra
using Random
using Statistics
using ProgressBars, Printf
using Flux.Optimise: update!
using Flux.Losses: mae
using BSON: @save, @load
using LatinHypercubeSampling
using LsqFit

is_restart = false;
n_epoch = 2000;
n_plot = 10;

opt = ADAMW(0.005, (0.9, 0.999), 1.f-6);
datasize = 40;
batchsize = 16;
n_exp_train = 20;
n_exp_val = 5;
n_exp = n_exp_train + n_exp_val; 
noise = 1.f-4;
ns = 3;
nr = 6;

grad_max = 10 ^ (0.5);
maxiters = 10000;

# alg = AutoTsit5(Rosenbrock23(autodiff=false));
alg = Rosenbrock23(autodiff=false);
atol = [1e-6, 1e-8, 1e-6];
rtol = [1e-3, 1e-3, 1e-3];
lb = 1e-8;
ub = 1.f1;

np = nr * (2 * ns + 1) + 1;
p = (rand(Float32, np) .- 0.5) * 2 * sqrt(6 / (ns + nr));
p[end] = 1.e-1;

# Generate datasets
u0_list = rand(Float32, (n_exp, ns)) .* 2 .+ 0.5;
u0_list[:, 2:2] .= 0 .+ lb;
u0_list[:, [1, 3]] .= randomLHC(n_exp, 2) ./ n_exp .+ 0.5

tsteps = 10 .^ range(0, 5, length=datasize);
tspan = Float32[0, tsteps[end]];
t_end = tsteps[end]

k = [4.f-2, 3.f7, 1.f4];
ode_data_list = zeros(Float32, (n_exp, ns, datasize));
yscale_list = [];

function trueODEfunc(dydt, y, k, t)
    r1 = k[1] * y[1]
    r2 = k[2] * y[2] * y[2]
    r3 = k[3] * y[2] * y[3]
    dydt[1] = -r1 + r3
    dydt[2] = r1 - r2 - r3
    dydt[3] = r2
end

u0 = u0_list[1, :];
prob_trueode = ODEProblem(trueODEfunc, u0, tspan, k);

function max_min(ode_data)
    return maximum(ode_data, dims=2) .- minimum(ode_data, dims=2)
end

for i = 1:n_exp
    u0 = u0_list[i, :]
    prob_trueode = ODEProblem(trueODEfunc, u0, tspan, k)
    ode_data = Array(solve(prob_trueode, alg, saveat=tsteps, atol=atol, rtol=rtol))
    ode_data += randn(size(ode_data)) .* ode_data .* noise
    ode_data_list[i, :, :] = ode_data
    push!(yscale_list, max_min(ode_data))
end

yscale = maximum(hcat(yscale_list...), dims=2);
dydt_scale = yscale[:, 1] ./ t_end
show(stdout, "text/plain", round.(yscale', digits=8))

function p2vec(p)
    slope = abs(p[end])
    w_b = @view(p[1:nr]) .* (10 * slope)

    w_in = reshape(@view(p[nr * (ns + 1) + 1:nr * (2 * ns + 1)]), ns, nr)

    w_out = reshape(@view(p[nr + 1:nr * (ns + 1)]), ns, nr)
    w_out = @. -w_in * (10 ^ w_out)

    w_in = clamp.(w_in, 0, 2.5)
    return w_in, w_b, w_out
end

function display_p(p)
    w_in, w_b, w_out = p2vec(p)
    println("species (column) reaction (row)")
    println("w_in | w_b | w_out")
    display(hcat(w_in', w_b, w_out'))

    println("w_out_scale")
    w_out_ = (w_out .* dydt_scale)' .* exp.(w_b)
    # display(w_out_)
    # display(maximum(abs.(w_out_), dims=2)')
    display(w_out_ ./ maximum(abs.(w_out_), dims=2))
    println("slope = $(p[end])")
end
display_p(p)

function crnn(du, u, p, t)
    w_in_x = w_in' * @. log(clamp(u, lb, Inf))
    du .= w_out * (@. exp(w_in_x + w_b)) .* dydt_scale
end

u0 = u0_list[1, :]
prob = ODEProblem(crnn, u0, tspan, saveat=tsteps, atol=atol, rtol=rtol)

sense = BacksolveAdjoint(checkpointing=true; autojacvec=false);
function predict_neuralode(u0, p; sample = datasize)
    global w_in, w_b, w_out = p2vec(p)
    _prob = remake(prob, tspan=[0, tsteps[sample]])
    sol = solve(prob, alg, u0=u0, p=p, saveat=tsteps[1:sample], 
                sensalg=sense, verbose=false, maxiters=maxiters)
    pred = Array(sol)

    if sol.retcode == :Success
        nothing
    else
        println("ode solver failed")
    end
    return pred
end
pred = predict_neuralode(u0, p);

function loss_neuralode(p, i_exp; sample = datasize)
    pred = predict_neuralode(u0_list[i_exp, :], p; sample)
    ode_data = ode_data_list[i_exp, :, 1:size(pred)[2]]
    loss = mae(ode_data ./ yscale, pred ./ yscale)
    return loss
end
loss_neuralode(p, 1)

cbi = function (p, i_exp)
    ode_data = ode_data_list[i_exp, :, :]
    pred = predict_neuralode(u0_list[i_exp, :], p)
    l_plt = []
    for i = 1:ns
        plt = scatter(tsteps, ode_data[i, :], xscale=:log10,
                      markercolor=:transparent, label=string("data"))
        plot!(plt, tsteps[1:size(pred)[2]], pred[i, :], xscale=:log10, label=string("pred"))
        ylabel!(plt, "y$i")
        if i == ns
            xlabel!(plt, "Time [s]")
            plot!(plt, legend=:topleft)
        else
            plot!(plt, legend=false)
        end
        push!(l_plt, plt)
    end
    plt_all = plot(l_plt..., framestyle=:box, layouts = (ns, 1))
    png(plt_all, string("figs/i_exp_", i_exp))

    return false
end

l_loss_train = []
l_loss_val = []
l_grad = []
iter = 1
cb = function (p, loss_train, loss_val, g_norm)
    global l_loss_train, l_loss_val, l_grad, iter
    push!(l_loss_train, loss_train)
    push!(l_loss_val, loss_val)
    push!(l_grad, g_norm)

    if iter % n_plot == 0
        display_p(p)

        l_exp = randperm(n_exp)[1:1]
        println("update plot for ", l_exp)
        for i_exp in l_exp
            cbi(p, i_exp)
        end

        plt_loss = plot(l_loss_train, xscale=:identity, yscale=:log10, label="train")
        plot!(plt_loss, l_loss_val, xscale=:identity, yscale=:log10, label="val")
        plt_grad = plot(l_grad, xscale=:identity, yscale=:log10, label="grad_norm")
        xlabel!(plt_loss, "Epoch")
        xlabel!(plt_grad, "Epoch")
        ylabel!(plt_loss, "Loss")
        ylabel!(plt_grad, "Grad Norm")
        ylims!(plt_loss, (-Inf, 1))
        plt_all = plot([plt_loss, plt_grad]..., legend=:top)
        png(plt_all, "figs/loss_grad")

        @save "./checkpoint/mymodel.bson" p opt l_loss_train l_loss_val l_grad iter
    end
    iter += 1
end

if is_restart
    @load "./checkpoint/mymodel.bson" p opt l_loss_train l_loss_val l_grad iter
    iter += 1
    # opt = ADAMW(0.001, (0.9, 0.999), 1.f-6)
end

function loss_lm(p)
    [loss_neuralode(p, i) for i in 1:n_exp_train]
end
loss_lm(p);

g = function (p)
    return ForwardDiff.jacobian(x -> loss_lm(x), p)
end
g(p);

epochs = ProgressBar(iter:n_epoch);
loss_epoch = zeros(Float32, n_exp);
grad_norm = zeros(Float32, n_exp_train);
for epoch in epochs
    global p
    for i_exp in randperm(n_exp_train)
        sample = rand(batchsize:datasize)
        grad = ForwardDiff.gradient(x -> loss_neuralode(x, i_exp; sample), p)
        grad_norm[i_exp] = norm(grad, 2)
        if grad_norm[i_exp] > grad_max
            grad = grad ./ grad_norm[i_exp] .* grad_max
        end
        update!(opt, p, grad)
    end
    for i_exp in 1:n_exp
        loss_epoch[i_exp] = loss_neuralode(p, i_exp)
    end
    loss_train = mean(loss_epoch[1:n_exp_train]);
    loss_val = mean(loss_epoch[n_exp_train + 1:end]);
    g_norm = mean(grad_norm)
    set_description(epochs, string(@sprintf("Loss train %.4e val %.4e gnorm %.4e", loss_train, loss_val, g_norm)))
    cb(p, loss_train, loss_val, g_norm);

    if loss_train < 0.1
        break
    end
end

fit = LsqFit.lmfit(loss_lm, g, p, Float64[]; show_trace=true, maxIter=2000, x_tol=1e-8)
p_fit = fit.param;
display_p(p_fit)
cbi(p_fit, 1)
cbi(p_fit, n_exp)

# @printf("min loss train %.4e val %.4e\n", minimum(l_loss_train), minimum(l_loss_val))

# for i_exp in 1:n_exp
#     cbi(p, i_exp)
# end
