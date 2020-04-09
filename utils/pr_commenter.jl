# GLOBALS that should be set
println("Running comment script")

# Set plot globals
ENV["PLOTS_TEST"] = "true"
ENV["GKSwstype"] = "100"

println("Defining functions")

# Stolen from https://discourse.julialang.org/t/collecting-all-output-from-shell-commands/15592/6
""" Read output from terminal command """
function communicate(cmd::Cmd, input)
    inp = Pipe()
    out = Pipe()
    err = Pipe()

    process = run(pipeline(cmd, stdin=inp, stdout=out, stderr=err), wait=false)
    close(out.in)
    close(err.in)

    stdout = @async String(read(out))
    stderr = @async String(read(err))
    write(process, input)
    close(inp)
    wait(process)
    return (
        stdout = fetch(stdout),
        stderr = fetch(stderr),
        code = process.exitcode
    )
end

""" Checkout ControlSystems PR"""
function checkout_ControlSystems_PR(org, origin, ID)
    Pkg.develop(Pkg.PackageSpec(url="https://github.com/$org/ControlSystems.jl.git"))
    dir = joinpath(Pkg.devdir(), "ControlSystems")
    cd(dir)
    run(`git fetch $origin pull/$ID/head:tests-$ID`)
    run(`git checkout tests-$ID`)
    return
end

""" Generate figures for plot tests"""
function gen_figures()
    #### Test Plots

    ControlExamplePlots.Plots.gr()
    ControlExamplePlots.Plots.default(show=false)

    funcs, refs, eps = getexamples()
    # Make it easier to pass tests on different systems
    # Set to a factor 2*2 of common errors
    eps = 2*[0.15, 0.015, 0.1, 0.01, 0.01, 0.02, 0.01, 0.15, 0.15, 0.01, 0.01]
    res = genplots(funcs, refs, eps=eps, popup=false)

    ndiff = count(r -> r.status != ControlExamplePlots.EXACT_MATCH, res)

    return res, ndiff
end

function create_ControlExamplePlots_branch(ID)
    dir = joinpath(Pkg.devdir(), "ControlExamplePlots")
    cd(dir)
    master_sha1 = communicate(`git rev-parse HEAD`, "useless string")[1][1:end-1] # strip newline
    tmp_name = UUIDs.uuid1()
    # Create new branch
    new_branch_name = "tests-$ID-$tmp_name"
    run(`git checkout -b $new_branch_name`)
    return master_sha1, new_branch_name
end


""" Replace old files with new and push to new branch"""
function replace_and_push_files(res, new_org, origin, new_branch_name)
    # Create dir for temporary figures
    dir = joinpath(Pkg.devdir(), "ControlExamplePlots")
    cd(dir)
    for r in res
        # Copy results into repo
        mv(r.testFilename, r.refFilename, force=true)
    end
    # Add figures
    run(`git config --global user.email "name@example.com"`)
    run(`git config --global user.name "JuliaControl Bot"`)
    run(`git add src/figures/*`)
    run(`git commit -m "automated plots test"`)
    run(`git remote add bot https://JuliaControlBot:$(ENV["ACCESS_TOKEN_BOT"])@github.com/$(new_org)/ControlExamplePlots.jl.git`)
    run(`git push -u bot $new_branch_name`)
    return
end

# Builds a message to post to github
function get_message(res, org, new_org, old_commit, new_branch_name)
    good = ":heavy_check_mark:"
    warning = ":warning:"
    error = ":x:"

    images_str = ""
    ndiff = 0
    for r in res
        if r.status != ControlExamplePlots.EXACT_MATCH
            ndiff += 1
            diff = (isdefined(r, :diff) && isa(r.diff, Number)) ? r.diff : 1.0
            # Symbol in front of number
            symbol = ( diff < 0.015 ? good : (diff < 0.03 ? warning : error))
            # Number/message we print
            status = (isdefined(r, :diff) && isa(r.diff, Number)) ? round(r.diff, digits=3) : string(r.status)
            # Name of file
            fig_name = basename(r.refFilename)
            # Append figure to message
            images_str *= "$symbol $status | ![Reference](https://raw.githubusercontent.com/$org/ControlExamplePlots.jl/$old_commit/src/figures/$(fig_name)) | ![New](https://raw.githubusercontent.com/$(new_org)/ControlExamplePlots.jl/$(new_branch_name)/src/figures/$(fig_name))\n"
        end
    end

    str = if ndiff > 0
        """This is an automated message.
        Plots were compared to references. $(ndiff)/$(length(res)) images have changed, see differences below:
        Difference | Reference Image | New Image
        -----------| ----------------| ---------
        """*images_str
    else
        """This is an automated message.
        Plots were compared to references. No changes were detected.
        """
    end
    return str
end

""" Post comment with result to original PR """
function post_comment(org, ID, message)
    token = ENV["ACCESS_TOKEN_BOT"]
    auth = GitHub.authenticate(token)
    #Push the comment
    GitHub.create_comment("$org/ControlSystems.jl", ID, :issue; auth = auth, params = Dict("body" => message))
end

println("Loading constants")
# Values
origin = "origin"
org = "JuliaControl"
new_org = "JuliaControlBot"
ID = ENV["PR_ID"]

try
    println("Running main script.")
    println("PR_ID is $(ENV["PR_ID"])")

    using Pkg

    # Makes sure we can push to this later
    println("deving ControlExamplePlots")
    Pkg.develop(Pkg.PackageSpec(url="https://github.com/$org/ControlExamplePlots.jl.git"))

    println("adding packages")
    Pkg.add("UUIDs")
    Pkg.add("GitHub")
    Pkg.add("ImageMagick") # Has no UUID

    println("running checkout_ControlSystems_PR")
    checkout_ControlSystems_PR(org, origin, ENV["PR_ID"])

    println("using ControlExamplePlots")
    using ControlExamplePlots

    println("running gen_figures")
    res, ndiff = gen_figures()

    println("$ndiff images have changes")
    import UUIDs

    if ndiff > 0
        println("running create_ControlExamplePlots_branch")
        old_commit, new_branch_name = create_ControlExamplePlots_branch(ID)

        println("running replace_and_push_files")
        replace_and_push_files(res, new_org, origin, new_branch_name)
    else
        println("No changes will be pushed")
    end

    println("running get_message")
    message = get_message(res, org, new_org, old_commit, new_branch_name)

    #### Post Comment
    import GitHub
    println("running post_comment")
    post_comment(org, ID, message)
    println("Done!")
catch
    println("BUILD FAILED!")

    message = "Something failed when generating plots. See the log at https://github.com/JuliaControl/ControlExamplePlots.jl/actions for more details."

    import GitHub
    println("running post_comment")
    post_comment(org, ID, message)
    println("Build failed, comment added to PR.")
    # Throw error to log
    rethrow()
end
