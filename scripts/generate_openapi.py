import yaml
from docling_serve.app import app

def generate_openapi_spec():
    with open("openapi.yaml", "w") as f:
        yaml.dump(app.openapi(), f, sort_keys=False)

if __name__ == "__main__":
    generate_openapi_spec() 