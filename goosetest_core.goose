// Configured goosetest entry point for the mochi-goose core target.

import goosetest from "../goosetest";
import vm from "./src/goose_vm";

import goosetest_generated.core.runner;

fn main() {
    exit(goosetest_generated::run_all());
}
