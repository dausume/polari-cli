#!/usr/bin/env node

const fs = require('fs');
const { execSync } = require('child_process');
const path = require('path');

const scriptPaths = {
    'test-cli': path.join(__dirname, 'scripts', 'test-cli.sh'),
    'uninstall': path.join(__dirname, 'scripts', 'uninstall.sh'),
    'run': path.join(__dirname, 'scripts', 'run.sh'),
    // Add other script paths here
};

const makeExecutable = (filePath) => {
    try {
      execSync(`chmod +x ${filePath}`);
      console.log(`Made ${filePath} executable.`);
    } catch (err) {
      console.error(`Failed to make ${filePath} executable.`);
    }
  };
  
  const validateScripts = () => {
    let allScriptsValid = true;
  
    Object.keys(scriptPaths).forEach((key) => {
      const filePath = scriptPaths[key];
      try {
        const stats = fs.statSync(filePath);
        if ((stats.mode & fs.constants.S_IXUSR) === 0) {
          console.log(`Script ${filePath} is not executable. Attempting to make it executable.`);
          makeExecutable(filePath);
  
          // Revalidate after attempting to make executable
          try {
            const newStats = fs.statSync(filePath);
            if ((newStats.mode & fs.constants.S_IXUSR) === 0) {
              console.error(`Error: Script ${filePath} is still not executable.`);
              allScriptsValid = false;
            }
          } catch (err) {
            console.error(`Error: Script ${filePath} does not exist.`);
            allScriptsValid = false;
          }
        }
      } catch (err) {
        console.error(`Error: Script ${filePath} does not exist.`);
        allScriptsValid = false;
      }
    });
  
    return allScriptsValid;
  };

const command = process.argv[2];

// Validate scripts on initialization
if (!validateScripts()) {
  process.exit(1);
}

switch (command) {
  case 'test-cli':
    execSync(`bash ${scriptPaths['test-cli']}`, { stdio: 'inherit' });
    break;
  case 'uninstall':
    execSync(`bash ${scriptPaths['uninstall']}`, { stdio: 'inherit' });
    break;
  case 'run':
    execSync(`bash ${scriptPaths['run']}`, { stdio: 'inherit' });
    break;
  case 'help':
    console.log(`Available commands:
      test-cli   - Test if the CLI is working
      run        - Run the application using Docker Compose
      uninstall  - Uninstall this CLI tool globally
      help       - Show this help message`);
    break;
  default:
    console.log('Unknown command. Use "help" to see available commands.');
    process.exit(1);
}
