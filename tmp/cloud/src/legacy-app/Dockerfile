# ============================================================
# Dockerfile for InventoryApp (.NET 8 modernized version)
# Used in Spoke3 containerization scenario
# ============================================================
# Stage 1: Build
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY InventoryApp.Modernized/*.csproj ./InventoryApp.Modernized/
RUN dotnet restore InventoryApp.Modernized/InventoryApp.Modernized.csproj

COPY InventoryApp.Modernized/ ./InventoryApp.Modernized/
RUN dotnet publish InventoryApp.Modernized/InventoryApp.Modernized.csproj \
    -c Release -o /app/publish

# Stage 2: Runtime
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app

EXPOSE 8080
ENV ASPNETCORE_URLS=http://+:8080

COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "InventoryApp.Modernized.dll"]
