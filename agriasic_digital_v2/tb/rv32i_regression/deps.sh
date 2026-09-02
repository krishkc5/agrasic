#!/bin/bash
source "$HOME/rv-venv/bin/activate"
pip install -q cocotbext-axi 2>&1 | tail -5
python -c "import cocotbext.axi; print('cocotbext.axi OK')"
