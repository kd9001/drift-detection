import boto3
import json
import os

codebuild = boto3.client('codebuild')

def lambda_handler(event, context):
    print("🚨 Console change detected! Triggering drift check...")
    print("Event:", json.dumps(event, indent=2))

    response = codebuild.start_build(
        projectName=os.environ['CODEBUILD_PROJECT_NAME']
    )

    build_id = response['build']['id']
    print(f"✅ CodeBuild triggered: {build_id}")

    return {
        'statusCode': 200,
        'body': f'Drift check triggered: {build_id}'
    }
