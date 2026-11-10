// Configured goosetest entry point for the mochi-gvm core target.

import goosetest from "../goosetest";
import vm from "./src/gvm";

import goosetest_generated.core.runner;

fn main() {
    exit(goosetest_generated::run_all());
}
