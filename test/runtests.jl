using MINDFul: getoxcview, OXCAddDropBypassSpectrumLLI
using MINDFul
using Test, TestSetExtensions
using Graphs
import AttributeGraphs as AG
using JLD2, UUIDs
using Unitful, UnitfulData

const MINDF = MINDFul

## single domain
include("testutils.jl")

include("testsuite/physicaltest.jl")
include("testsuite/basicintenttest.jl")
# include("testsuite/multidomain.jl")

nothing
