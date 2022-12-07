<div align="center">
  <h1 align="center"> Lyra V2 Core</h1>

<p align='center'>
    <br>
    <br>
    <img src='./docs/imgs/overall/logo.png' alt='lyra' width="300" />
    <h5 align="center"> Cool slogan goes here </h6>
</p> 
</div>

## Installation and Build

```shell
git submodule update --init --recursive
forge build
```

## Running different tests

Only running unit tests

```shell
forge test --match-contract="UNIT_" -vvv
```

Running POC tests

```shell
forge test --match-contract="POC_" -vvv
```

## Documentation

Go to [docs](./docs) to understand the high level of the design, transaction flow and how different **Lyra v2 components** works together.

## Static Analysis - Slither
 
### Installation

```shell
pip3 install slither-analyzer
pip3 install solc-select
solc-select install 0.8.13
solc-select use 0.8.13
```

### Run analysis

```shell
slither src --exclude-low
```

### To Triage findings

Make sure to triage all findings introduced by new PR. They should be added to `slither.db`.

```shell
slither src --exclude-low --triage-mode
```