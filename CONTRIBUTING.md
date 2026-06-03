# Contributing to Claude Code Observability Stack

Thank you for your interest in contributing to the Claude Code Observability Stack! This project helps developers monitor and analyze their Claude Code usage through comprehensive dashboards and metrics.

## 🚀 Getting Started

### Prerequisites
- Docker and Docker Compose
- Basic understanding of OpenTelemetry, Prometheus, and Grafana
- Familiarity with Claude Code and its telemetry features

### Development Setup
1. Fork the repository
2. Clone your fork: `git clone https://github.com/your-username/catalyst-otel.git`
   - Canonical repository: `git clone https://github.com/coalesce-labs/catalyst-otel.git`
   - Original upstream project: `git clone https://github.com/ColeMurray/claude-code-otel.git`
3. Start the development stack: `make up`
4. Access Grafana at http://localhost:3000 (admin/admin)

## 📊 How to Contribute

### Dashboard Improvements
- Add new panels for additional Claude Code metrics
- Improve existing visualizations for better insights
- Optimize queries for better performance
- Enhance color schemes and layouts

### Configuration Enhancements
- Improve OpenTelemetry collector configurations
- Add new Prometheus recording rules
- Optimize data retention and storage

### Documentation
- Improve setup instructions
- Add troubleshooting guides
- Create usage examples
- Update metric documentation

## 🔍 Project Structure

```
├── claude-code-dashboard.json    # Main Grafana dashboard
├── collector-config.yaml         # OpenTelemetry collector config
├── docker-compose.yml           # Main stack configuration
├── prometheus.yml               # Prometheus configuration
├── grafana-*.yml               # Grafana configuration files
├── Makefile                    # Management commands
└── README.md                   # Project documentation
```

## 📋 Contribution Guidelines

### Code Quality
1. **Follow OpenTelemetry Standards**: Use proper metric naming conventions as defined in the Claude Code documentation
2. **Test Your Changes**: Verify that new configurations work with actual Claude Code telemetry data
3. **Documentation**: Update relevant documentation for any changes
4. **Security**: Never commit sensitive information (API keys, credentials, etc.)

### Dashboard Guidelines
1. **Consistent Styling**: Follow the existing color schemes and layout patterns
2. **Performance**: Optimize queries to avoid excessive resource usage
3. **Accessibility**: Use clear labels and legends for all visualizations
4. **Mobile-Friendly**: Ensure dashboards work well on different screen sizes

### Commit Messages
Use clear, descriptive commit messages:
- `feat: add API request count panel to cost analysis`
- `fix: correct token usage query in performance dashboard`
- `docs: update setup instructions for macOS`
- `refactor: optimize Prometheus queries for better performance`

## 🧪 Testing Your Changes

### Before Submitting a PR
1. **Start the Stack**: `make up`
2. **Generate Test Data**: Use Claude Code with telemetry enabled
3. **Verify Dashboards**: Check that all panels display data correctly
4. **Test Configuration**: Ensure `make validate-config` passes
5. **Check Documentation**: Verify all links and instructions work

### Configuration Validation
```bash
# Validate all configurations
make validate-config

# Test individual components
docker compose config  # Validate docker-compose.yml
curl -f http://localhost:9090/-/healthy  # Test Prometheus
curl -f http://localhost:3000/api/health  # Test Grafana
```

## 📈 Types of Contributions

### Dashboard Enhancements
- **New Metric Panels**: Add visualizations for additional Claude Code metrics
- **Improved Layouts**: Better organization of dashboard sections
- **Enhanced Queries**: More efficient or insightful Prometheus/LogQL queries
- **Visual Improvements**: Better color schemes, legends, and formatting

### Infrastructure Improvements
- **Performance Optimization**: Faster queries and reduced resource usage
- **Configuration Management**: Better default configurations
- **Documentation**: Clearer setup and troubleshooting guides
- **Compatibility**: Support for different environments and setups

### Feature Additions
- **New Metrics**: Support for additional Claude Code telemetry data
- **Export Options**: Additional data export formats or integrations
- **Monitoring Enhancements**: Better health checks and status monitoring

## 🐛 Reporting Issues

When reporting issues, please include:
1. **Environment Details**: OS, Docker version, Claude Code version
2. **Steps to Reproduce**: Clear instructions to replicate the issue
3. **Expected vs Actual**: What you expected to happen vs what actually happened
4. **Logs**: Relevant logs from the observability stack
5. **Configuration**: Any custom configurations you're using

## 📚 Resources

- [Claude Code Observability Documentation](CLAUDE_OBSERVABILITY.md)
- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [Prometheus Query Language](https://prometheus.io/docs/prometheus/latest/querying/)
- [Grafana Dashboard Best Practices](https://grafana.com/docs/grafana/latest/best-practices/)
- [LogQL Documentation](https://grafana.com/docs/loki/latest/logql/)

## 💬 Getting Help

- **Issues**: Open a GitHub issue for bugs or feature requests
- **Discussions**: Use GitHub Discussions for questions and ideas
- **Documentation**: Check the README and CLAUDE_OBSERVABILITY.md first

## 📋 Pull Request Process

1. **Fork & Branch**: Create a feature branch from `main`
2. **Develop**: Make your changes following the guidelines above
3. **Test**: Verify your changes work as expected
4. **Document**: Update documentation if needed
5. **Submit**: Create a pull request with a clear description

### PR Description Template
```markdown
## Summary
Brief description of changes

## Type of Change
- [ ] Dashboard improvement
- [ ] Configuration enhancement
- [ ] Documentation update
- [ ] Bug fix
- [ ] New feature

## Testing
- [ ] Tested with actual Claude Code telemetry data
- [ ] Verified all dashboard panels work correctly
- [ ] Configuration validation passes
- [ ] Documentation is accurate

## Screenshots (if applicable)
Include screenshots of dashboard changes
```

Thank you for contributing to the Claude Code Observability Stack! 🚀 