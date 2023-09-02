# 
# Generate a sitemap for NASA's Generic Kernel URL! 
# This requires the program `lynx` to be installed.
# 

using HTTP
using Dates
using IOCapture
using SPICEKernels
using SPICEApplications: brief, ckbrief, dskbrief, commnt

"""
Call the `lynx` commandline program in a non-interactive context.
"""
function lynx(url::AbstractString)
    contents = IOCapture.capture() do 
       run(`lynx -dump -listonly -nonumbers "$url"`) 
    end
    
    lines = split(contents.output)
    return Set(map(String, lines))
end

"""
Given a Generic Kernel URL or sub-URL, return a set of kernel file paths and subdirectories.
"""
function search(
        url::AbstractString; 
        ignore = ("?", "LYNXIMGMAP", "#", "old_versions", "README"), 
        accept = (SPICEKernels.GENERIC_KERNEL_URL, "dsk", "fk", "lsk", "pck", "spk", "stars", keys(SPICEKernels.SPICE_EXTENSIONS)...)
    )

    paths = lynx(url)

    filter!(path -> !any(occursin(key, path) for key in ignore), paths)
    filter!(path -> any(occursin(key, path) for key in accept), paths)
    filter!(path -> path != HTTP.safer_joinpath(replace(url, basename(url) => ""), ""), paths)

    return paths
end

"""
Given a top-level directory, return the set of all kernel file paths found in all subdirectories.
"""
function traverse(url::AbstractString; searched::AbstractSet{<:AbstractString} = Set{String}())

    url = HTTP.safer_joinpath(url, "")
    @debug "Searching for kernels in $url"

    found = Set{String}()
    paths = search(url)
    push!(searched, url)

    setdiff!(paths, searched)

    for path in paths
        push!(searched, path)
        if any(occursin(ext, basename(path)) for ext in keys(SPICEKernels.SPICE_EXTENSIONS))
            push!(found, path)
        elseif !occursin(".", basename(path))
            union!(found, traverse(path; searched = searched))
        end
    end

    return found
end

"""
Write all current kernel paths to the provided file name.
"""
function code!(kernels::AbstractSet{<:AbstractString}; force::Bool = false)

    kernellist = collect(kernels)
    sort!(kernellist)

    mappath = abspath(joinpath(@__DIR__, "..", "src", "gen", "map.jl"))

    open(mappath, "w") do file
        write(file, "#\n# This is an autogenerated file! See gen/make.jl for more information.\n#\n\n")
        write(file, """\"\"\"\nLinks to all Generic Kernels hosted by naif.jpl.nasa.gov, as of $(today()). [1]\n\n# Extended Help\n\n## References\n\n[1] https://naif.jpl.nasa.gov/pub/naif/generic_kernels/\n\"\"\"\n""")
        write(file, "const GENERIC_KERNELS = Base.ImmutableDict(\n")
        for kernel in kernellist
            write(file, """    "$(basename(kernel))" => "$kernel",\n""")
        end
        write(file, ")\n\n")
    end

    IOCapture.capture() do 
        try
            run(`git diff --exit-code $mappath`)
        catch e
            if e isa ProcessFailedException
                force = true
            else
                rethrow(e)
            end
        end
    end

    if force
        kernelpath = abspath(joinpath(@__DIR__, "..", "src", "gen", "kernels.jl"))

        sanitize(name::AbstractString) = split(replace(name, "-" => "_"), ".") |> first |> String
        implement(name::AbstractString) = let
            T = SPICEKernels.type(name)
            M = Base.ImmutableDict(
                SPICEKernels.EphemerisKernel => SPICEKernels.SPK,
                SPICEKernels.DigitalShapeKernel => SPICEKernels.DSK,
                SPICEKernels.PlanetaryConstantsKernel => SPICEKernels.PCK,
                SPICEKernels.FramesKernel => SPICEKernels.FK,
                SPICEKernels.LeapSecondsKernel => SPICEKernels.LSK,
            )
            
            M[T]
        end

        size(file::AbstractString) = let 
            bytes = filesize(file)

            KB = 1024
            MB = KB^2
            GB = KB^3
            if bytes >= GB
                return "$(round(bytes / GB, digits=1)) GB"
            elseif bytes >= MB
                return "$(round(bytes / MB, digits=1)) MB"
            else
                return "$(round(bytes / KB, digits=1)) KB"
            end
        end

        description(path::AbstractString) = let 

            extension = last(splitext(path))

            if extension in (".bsp", ".bpc")
                desc = IOCapture.capture() do 
                    brief(path) 
                end
            elseif extension == ".tsp"
                desc = IOCapture.capture() do 
                    ckbrief(path) 
                end
            elseif extension in (".dsk", ".bds")
                desc = IOCapture.capture() do 
                    dskbrief(path) 
                end
            else
                @debug "Uncaught extension \"$extension\""
                desc = "A `$(SPICEKernels.type(path))`. If the kernel type is not binary, open the file for more information!"
            end

            desc = desc isa String ? desc : convert(String, desc.output)

            return replace(desc, joinpath(SPICEKernels.SPICE_KERNEL_DIR, "") => "")
        end

        toexport = String[]
        open(kernelpath, "w") do file
            write(file, "#\n# This is an autogenerated file! See gen/make.jl for more information.\n#\n\n")
            for kernel in kernellist
                if !endswith(kernel, ".pc")
                    path = SPICEKernels.fetchkernel(kernel, ignorecache=true)
                    name = sanitize(basename(kernel))
                    type = implement(kernel)

                    if count(k -> sanitize(basename(k)) == name, kernellist) > 1
                        name = name * "_" * lowercase(last(split(string(type), ".")))
                    end

                    push!(toexport, name)

                    write(file, """\n\"\"\"\nA $type kernel of size $(size(path)), linked from https://naif.jpl.nasa.gov [1].\nCalling this variable like a function will return a path to the file, downloading \nto scratchspace if necessary.\n\n# Extended Help\n\n This kernel's link was sourced on $(today()).\n\n## References\n\n[1] $kernel\n\n## Description\n\n```\n$(description(path))\n```\n\"\"\"\n""")
                    if "$kernel.pc" in kernellist
                        write(file, """const $name = $type(!Sys.iswindows() ? "$kernel" : "$kernel.pc")\n""")
                    else
                        write(file, """const $name = $type("$kernel")\n""")
                    end

                    rm(path)
                end
            end
            write(file, "\nexport\n    ")
            write(file, join(toexport, ",\n    "))
        end
    end

    return nothing
end

# 
# The script portion!
# 

code!(traverse(SPICEKernels.GENERIC_KERNEL_URL); force = "--force" in lowercase.(ARGS))